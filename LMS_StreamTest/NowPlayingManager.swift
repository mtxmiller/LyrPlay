// File: NowPlayingManager.swift
// Enhanced to use server time as primary source for lock screen accuracy
import Foundation
import MediaPlayer
import UIKit
import os.log

protocol NowPlayingManagerDelegate: AnyObject {
    func nowPlayingDidReceivePlayCommand()
    func nowPlayingDidReceivePauseCommand()
    func nowPlayingDidReceiveNextTrackCommand()
    func nowPlayingDidReceivePreviousTrackCommand()
}

class NowPlayingManager: ObservableObject {
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "NowPlayingManager")
    
    // MARK: - Track Metadata
    private var currentTrackTitle: String = "LyrPlay"
    private var currentArtist: String = "Unknown Artist"
    private var currentAlbum: String = "Lyrion Music Server"
    private var currentArtwork: UIImage?
    private var metadataDuration: TimeInterval = 0.0
    
    // MARK: - SimpleTimeTracker Integration (Main Branch Approach)
    private weak var simpleTimeTracker: SimpleTimeTracker?
    private var lastKnownAudioTime: Double = 0.0
    
    // MARK: - Delegation
    weak var delegate: NowPlayingManagerDelegate?
    
    // MARK: - Lock Screen Command Reference
    weak var slimClient: SlimProtoCoordinator?
    
    // MARK: - Update Timer (Reduced frequency for SimpleTimeTracker)
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 0.5
    
    // MARK: - Initialization
    init() {
        setupNowPlayingInfo()
        setupRemoteCommandCenter()
        startUpdateTimer()
        //os_log(.info, log: logger, "Enhanced NowPlayingManager initialized with server time support")
    }
    
    // MARK: - SimpleTimeTracker Integration
    
    func setSimpleTimeTracker(_ tracker: SimpleTimeTracker) {
        self.simpleTimeTracker = tracker
        os_log(.info, log: logger, "✅ SimpleTimeTracker connected for timing")
    }
    
    // MARK: - Update Timer Management
    private func startUpdateTimer() {
        stopUpdateTimer()
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateNowPlayingTime()
        }
        
        //os_log(.debug, log: logger, "🔄 Now playing update timer started")
    }
    
    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private func updateNowPlayingTime() {
        // CORRECTED APPROACH: Use SimpleTimeTracker.getCurrentTime() for timing
        guard let tracker = simpleTimeTracker else {
            os_log(.debug, log: logger, "⏰ No SimpleTimeTracker available")
            return
        }
        
        let (currentTime, isPlaying) = tracker.getCurrentTime()
        
        // DIAGNOSTIC: Trace timer-based lock screen updates
        os_log(.debug, log: logger, "⏰ SimpleTimeTracker update: %.2fs (playing: %{public}s)",
               currentTime, isPlaying ? "YES" : "NO")
        
        // Update now playing info with SimpleTimeTracker time
        updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
    }
    
    // MARK: - SimpleTimeTracker Integration (Material-Style)
    private func getCurrentPlaybackInfo() -> (time: Double, isPlaying: Bool) {
        // CORRECTED APPROACH: Always use SimpleTimeTracker as single source of truth
        guard let tracker = simpleTimeTracker else {
            os_log(.debug, log: logger, "🔒 No SimpleTimeTracker available, returning 0.0")
            return (0.0, false)
        }
        
        let (currentTime, isPlaying) = tracker.getCurrentTime()
        
        os_log(.debug, log: logger, "🔒 SimpleTimeTracker time: %.2f (playing: %{public}s)",
               currentTime, isPlaying ? "YES" : "NO")
        
        return (currentTime, isPlaying)
    }
    
    // MARK: - Position Storage (Removed - SimpleTimeTracker handles this)
    // Position storage and recovery logic removed in favor of SimpleTimeTracker approach
    // Server time anchor + interpolation automatically handles disconnections and recovery
    
    // MARK: - Now Playing Info Setup
    private func setupNowPlayingInfo() {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentTrackTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentArtist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentAlbum
        
        // Add artwork if available
        if let artwork = currentArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                return artwork
            }
        }
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        os_log(.info, log: logger, "✅ Initial now playing info configured")
    }
    
    // MARK: - Remote Command Center Setup
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Disable all controls first
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        
        // Remove all existing targets
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        
        // Enable only the controls we want
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        
        // Add handlers for enabled controls - SERVER CONTROL ONLY
        commandCenter.playCommand.addTarget { [weak self] _ in
            os_log(.info, log: self?.logger ?? OSLog.disabled, "🎵 Lock Screen PLAY command received")
            if self?.slimClient != nil {
                os_log(.info, log: self?.logger ?? OSLog.disabled, "✅ Sending PLAY command to server")
                self?.slimClient?.sendLockScreenCommand("play")
            } else {
                os_log(.error, log: self?.logger ?? OSLog.disabled, "❌ slimClient is nil - cannot send PLAY command")
            }
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            os_log(.info, log: self?.logger ?? OSLog.disabled, "⏸️ Lock Screen PAUSE command received")
            if self?.slimClient != nil {
                os_log(.info, log: self?.logger ?? OSLog.disabled, "✅ Sending PAUSE command to server")
                self?.slimClient?.sendLockScreenCommand("pause")
            } else {
                os_log(.error, log: self?.logger ?? OSLog.disabled, "❌ slimClient is nil - cannot send PAUSE command")
            }
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            os_log(.info, log: self?.logger ?? OSLog.disabled, "⏭️ Lock Screen NEXT TRACK command received")
            if self?.slimClient != nil {
                os_log(.info, log: self?.logger ?? OSLog.disabled, "✅ Sending NEXT command to server")
                self?.slimClient?.sendLockScreenCommand("next")
            } else {
                os_log(.error, log: self?.logger ?? OSLog.disabled, "❌ slimClient is nil - cannot send NEXT command")
            }
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            os_log(.info, log: self?.logger ?? OSLog.disabled, "⏮️ Lock Screen PREVIOUS TRACK command received")
            if self?.slimClient != nil {
                os_log(.info, log: self?.logger ?? OSLog.disabled, "✅ Sending PREVIOUS command to server")
                self?.slimClient?.sendLockScreenCommand("previous")
            } else {
                os_log(.error, log: self?.logger ?? OSLog.disabled, "❌ slimClient is nil - cannot send PREVIOUS command")
            }
            return .success
        }
        
        os_log(.info, log: logger, "✅ Remote Command Center configured with track skip controls")
    }
    
    // MARK: - Track Metadata Management
    func updateTrackMetadata(title: String, artist: String, album: String, artworkURL: String? = nil, duration: TimeInterval? = nil) {
        // Only update duration if explicitly provided (Material skin approach)
        if let duration = duration {
            os_log(.info, log: logger, "🎵 Updating track metadata: %{public}s - %{public}s (%.0f sec)", title, artist, duration)
            metadataDuration = duration
        } else {
            os_log(.info, log: logger, "🎵 Updating track metadata: %{public}s - %{public}s", title, artist)
        }
        
        currentTrackTitle = title
        currentArtist = artist
        currentAlbum = album
        
        // Load artwork if URL provided
        if let artworkURL = artworkURL, let url = URL(string: artworkURL) {
            loadArtwork(from: url)
        } else {
            currentArtwork = nil
            // Update immediately without artwork
            let (currentTime, isPlaying) = getCurrentPlaybackInfo()
            updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
        }
    }
    
    private func loadArtwork(from url: URL) {
        os_log(.info, log: logger, "🖼️ Loading artwork from: %{public}s", url.absoluteString)
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self?.logger ?? OSLog.disabled, "❌ Failed to load artwork: %{public}s", error.localizedDescription)
                    self?.currentArtwork = nil
                } else if let data = data, let image = UIImage(data: data) {
                    os_log(.info, log: self?.logger ?? OSLog.disabled, "✅ Artwork loaded successfully")
                    self?.currentArtwork = image
                } else {
                    os_log(.error, log: self?.logger ?? OSLog.disabled, "❌ Invalid artwork data")
                    self?.currentArtwork = nil
                }
                
                // Update now playing info with or without artwork
                if let self = self {
                    let (currentTime, isPlaying) = self.getCurrentPlaybackInfo()
                    self.updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
                }
            }
        }.resume()
    }
    
    // MARK: - Now Playing Info Updates
    private func updateNowPlayingInfo(isPlaying: Bool, currentTime: Double = 0.0) {
        //os_log(.debug, log: logger, "🔒 SETTING LOCK SCREEN: %.2f (playing: %{public}s)",
         //      currentTime, isPlaying ? "YES" : "NO")
        
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        
        // Update basic metadata
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentTrackTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentArtist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentAlbum
        
        // Update playback state
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        
        // Add artwork if available
        if let artwork = currentArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                return artwork
            }
        }
        
        // Set duration using metadata duration for progress display
        if metadataDuration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = metadataDuration
        } else {
            // For live streams, remove duration info
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }
    
    // MARK: - Backward Compatibility (keeping interface for AudioManager)
    func updatePlaybackState(isPlaying: Bool, currentTime: Double) {
        // CORRECTED APPROACH: AudioManager updates are diagnostic only
        // SimpleTimeTracker timer provides actual timing updates
        os_log(.debug, log: logger, "🔄 AudioManager diagnostic update: %.2fs, playing=%{public}s", 
               currentTime, isPlaying ? "YES" : "NO")
        
        // Store last audio time for debugging/comparison
        lastKnownAudioTime = currentTime
        
        // No direct lock screen updates - SimpleTimeTracker timer handles this
    }
    
    // MARK: - Server Time Integration (Material-Style)
    func updateFromSlimProto(currentTime: Double, duration: Double = 0.0, isPlaying: Bool) {
        // CORRECTED APPROACH: Server time updates handled by SimpleTimeTracker
        // This method is for immediate metadata updates only
        
        // Update duration if provided
        if duration > 0 {
            metadataDuration = duration
        }
        
        // SimpleTimeTracker handles the timing, we just note the update
        os_log(.debug, log: logger, "📍 SlimProto metadata update: %.2f (playing: %{public}s)",
               currentTime, isPlaying ? "YES" : "NO")
        
        // Trigger immediate lock screen update for metadata changes
        let (trackerTime, trackerPlaying) = getCurrentPlaybackInfo()
        updateNowPlayingInfo(isPlaying: trackerPlaying, currentTime: trackerTime)
    }
    
    // MARK: - Metadata Access
    func getCurrentTrackTitle() -> String {
        return currentTrackTitle
    }
    
    func getCurrentArtist() -> String {
        return currentArtist
    }
    
    func getCurrentAlbum() -> String {
        return currentAlbum
    }
    
    func getMetadataDuration() -> TimeInterval {
        return metadataDuration
    }
    
    func hasArtwork() -> Bool {
        return currentArtwork != nil
    }
    
    // MARK: - Lock Screen Integration
    func setSlimClient(_ slimClient: SlimProtoCoordinator) {
        self.slimClient = slimClient
        os_log(.info, log: logger, "✅ SlimProto client reference set for lock screen commands")
    }
    
    // MARK: - Clear Now Playing Info
    func clearNowPlayingInfo() {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        nowPlayingInfoCenter.nowPlayingInfo = nil
        
        // Reset to defaults
        currentTrackTitle = "LyrPlay"
        currentArtist = "Unknown Artist"
        currentAlbum = "Lyrion Music Server"
        currentArtwork = nil
        metadataDuration = 0.0
        lastKnownAudioTime = 0.0
        
        os_log(.info, log: logger, "🗑️ Now playing info cleared")
    }
    
    // MARK: - Remote Command State
    func enableRemoteCommands(_ enable: Bool) {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = enable
        commandCenter.pauseCommand.isEnabled = enable
        commandCenter.nextTrackCommand.isEnabled = enable
        commandCenter.previousTrackCommand.isEnabled = enable
        
        os_log(.info, log: logger, "🎛️ Remote commands %{public}s", enable ? "enabled" : "disabled")
    }
    
    // MARK: - Debug Information
    func getTimeSourceInfo() -> String {
        let (currentTime, isPlaying) = getCurrentPlaybackInfo()
        let trackerStatus = simpleTimeTracker?.isTimeFresh() ?? false ? "Fresh" : "Stale"
        
        return """
        Time: \(String(format: "%.1f", currentTime))s (SimpleTimeTracker)
        Playing: \(isPlaying ? "Yes" : "No")
        Tracker: \(trackerStatus)
        """
    }
    
    // MARK: - Cleanup
    deinit {
        stopUpdateTimer()
        clearNowPlayingInfo()
        enableRemoteCommands(false)
        os_log(.info, log: logger, "Enhanced NowPlayingManager deinitialized")
    }
}

