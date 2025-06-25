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
    private var currentTrackTitle: String = "LMS Stream"
    private var currentArtist: String = "Unknown Artist"
    private var currentAlbum: String = "Lyrion Music Server"
    private var currentArtwork: UIImage?
    private var metadataDuration: TimeInterval = 0.0
    
    // MARK: - Time Sources
    private var serverTimeSynchronizer: ServerTimeSynchronizer?
    private weak var audioManager: AudioManager?
    private var lastKnownServerTime: Double = 0.0
    private var lastKnownAudioTime: Double = 0.0
    private var isUsingServerTime: Bool = false
    
    private var lockScreenStoredPosition: Double = 0.0
    private var lockScreenStoredTimestamp: Date?
    private var lockScreenWasPlaying: Bool = false
    private var connectionLostTime: Date?
    
    // MARK: - Delegation
    weak var delegate: NowPlayingManagerDelegate?
    
    // MARK: - Lock Screen Command Reference
    weak var slimClient: SlimProtoCoordinator?
    
    // MARK: - Update Timer
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 1.0
    
    // MARK: - Initialization
    init() {
        setupNowPlayingInfo()
        setupRemoteCommandCenter()
        startUpdateTimer()
        //os_log(.info, log: logger, "Enhanced NowPlayingManager initialized with server time support")
    }
    
    // MARK: - Server Time Integration
    func setServerTimeSynchronizer(_ synchronizer: ServerTimeSynchronizer) {
        self.serverTimeSynchronizer = synchronizer
        synchronizer.delegate = self
        //os_log(.info, log: logger, "✅ Server time synchronizer connected")
    }
    
    func setAudioManager(_ audioManager: AudioManager) {
        self.audioManager = audioManager
        //os_log(.info, log: logger, "✅ Audio manager connected for fallback timing")
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
        let (currentTime, isPlaying, timeSource) = getCurrentPlaybackInfo()
        
        // Log every update to see what's changing the lock screen
        //os_log(.debug, log: logger, "🔒 LOCK SCREEN UPDATE: %.2f (%{public}s, playing: %{public}s)",
         //      currentTime, timeSource.description, isPlaying ? "YES" : "NO")
        
        // Update now playing info with current time
        updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
        
        // Log time source changes
        let newUsingServerTime = (timeSource == .serverTime)
        if newUsingServerTime != isUsingServerTime {
            isUsingServerTime = newUsingServerTime
            //os_log(.info, log: logger, "🔒 TIME SOURCE CHANGED: %{public}s → %{public}s",
           //        isUsingServerTime ? "Server" : "Other", timeSource.description)
        }
    }
    
    // MARK: - Time Source Management
    private enum TimeSource {
        case serverTime
        case audioManager
        case lastKnown
        
        var description: String {
            switch self {
            case .serverTime: return "Server Time"
            case .audioManager: return "Audio Manager"
            case .lastKnown: return "Last Known"
            }
        }
    }
    
    private func getCurrentPlaybackInfo() -> (time: Double, isPlaying: Bool, source: TimeSource) {
        
        // CRITICAL FIX: If we have a stored recovery position, use it during disconnection periods
        if let storedTimestamp = lockScreenStoredTimestamp {
            let timeSinceStorage = Date().timeIntervalSince(storedTimestamp)
            
            // If we stored a position recently (within 2 minutes) and we're disconnected, use stored position
            if timeSinceStorage < 120.0 && lockScreenStoredPosition > 0.1 {
                let recoveryInfo = getStoredPositionWithTimeOffset()
                if recoveryInfo.isValid {
                    //os_log(.debug, log: logger, "🔒 Using stored recovery position: %.2f (%.1fs ago)",
                    //       recoveryInfo.position, timeSinceStorage)
                    
                    return (time: recoveryInfo.position, isPlaying: recoveryInfo.wasPlaying, source: .lastKnown)
                }
            }
        }
        
        // ENHANCED: If we have ANY server time data, use it - even if marked as "invalid"
        if let synchronizer = serverTimeSynchronizer {
            let serverInfo = synchronizer.getCurrentInterpolatedTime()
            
            // CRITICAL FIX: Use server time if it's > 0.1 seconds (not just > 0)
            // This prevents using bogus 0.00 positions from pause commands
            if serverInfo.time > 0.1 {
                //os_log(.debug, log: logger, "🔒 Using server time: %.2f (marked valid: %{public}s)",
                 //      serverInfo.time, serverInfo.isServerTime ? "YES" : "NO")
                
                lastKnownServerTime = serverInfo.time
                return (time: serverInfo.time, isPlaying: serverInfo.isPlaying, source: .serverTime)
            } else {
                // Server time is 0 or very small - use last known good server time if available
                if lastKnownServerTime > 0.1 {
                    //os_log(.debug, log: logger, "🔒 Server time is %.2f, using last known good: %.2f",
                   //       serverInfo.time, lastKnownServerTime)
                    
                    return (time: lastKnownServerTime, isPlaying: serverInfo.isPlaying, source: .serverTime)
                }
            }
        }
        
        // Only fall back to audio manager if we have NO good server data at all
        if let audioManager = audioManager {
            let audioTime = audioManager.getCurrentTime()
            let isPlaying = audioManager.getPlayerState() == "Playing"
            
            // CRITICAL FIX: Only use audio time if it's reasonable and different from our last server time
            if audioTime > 0.1 && abs(audioTime - lastKnownServerTime) < 120.0 {
                //os_log(.debug, log: logger, "🔒 Using audio time: %.2f (server time unavailable)", audioTime)
                lastKnownAudioTime = audioTime
                return (time: audioTime, isPlaying: isPlaying, source: .audioManager)
            }
        }
        
        // Ultimate fallback - use the best time we have
        let fallbackTime = max(lastKnownServerTime, lastKnownAudioTime, lockScreenStoredPosition)
        //os_log(.debug, log: logger, "🔒 Using ultimate fallback time: %.2f", fallbackTime)
        
        return (time: fallbackTime, isPlaying: false, source: .lastKnown)
    }
    
    // MARK : STORE POSITION
    func storeLockScreenPosition() {
        let (currentTime, isPlaying, source) = getCurrentPlaybackInfo()
        
        //os_log(.info, log: logger, "🔒 STORAGE CALL - Current: %.2f, Previously stored: %.2f",
        //       currentTime, lockScreenStoredPosition)
        
        // Show what time sources are available
        var serverTime: Double = 0.0
        var serverValid: Bool = false
        
        if let synchronizer = serverTimeSynchronizer {
            let serverInfo = synchronizer.getCurrentInterpolatedTime()
            serverTime = serverInfo.time
            serverValid = serverInfo.isServerTime
            //os_log(.info, log: logger, "🔒 SERVER TIME: %.2f (valid: %{public}s)",
            //       serverTime, serverValid ? "YES" : "NO")
        }
        
        if let audioManager = audioManager {
            let audioTime = audioManager.getCurrentTime()
            //os_log(.info, log: logger, "🔒 AUDIO TIME: %.2f", audioTime)
        }
        
        // IMPROVED LOGIC: Prefer last known good server time over audio time
        var positionToStore: Double = 0.0
        var sourceUsed: String = "none"
        
        // 1. Try current server time (if valid and reasonable)
        if serverValid && serverTime > 0.1 {
            positionToStore = serverTime
            sourceUsed = "current server time"
        }
        // 2. Try last known good server time (if current server time is invalid)
        else if !serverValid && lastKnownServerTime > 0.1 {
            positionToStore = lastKnownServerTime
            sourceUsed = "last known server time"
            //os_log(.info, log: logger, "🔒 Using last known server time: %.2f (current server invalid)", lastKnownServerTime)
        }
        // 3. Fall back to audio manager time
        else if let audioManager = audioManager {
            let audioTime = audioManager.getCurrentTime()
            if audioTime > 0.1 {
                positionToStore = audioTime
                sourceUsed = "audio manager time"
                //os_log(.info, log: logger, "🔒 Falling back to audio time: %.2f (no good server time)", audioTime)
            }
        }
        
        // Only store if we got a valid position
        if positionToStore > 0.1 {
            lockScreenStoredPosition = positionToStore
            lockScreenStoredTimestamp = Date()
            lockScreenWasPlaying = isPlaying
            connectionLostTime = Date()
            
            //os_log(.info, log: logger, "🔒 STORED NEW POSITION: %.2f (source: %{public}s)",
            //       positionToStore, sourceUsed)
        } else {
            //os_log(.error, log: logger, "🔒 STORAGE REJECTED - No valid position found (server: %.2f, audio: %.2f)",
            //       serverTime, currentTime)
        }
    }

    // Add this method to get stored position with time adjustment
    func getStoredPositionWithTimeOffset() -> (position: Double, wasPlaying: Bool, isValid: Bool) {
        os_log(.info, log: logger, "🔒 RECOVERY REQUEST STARTED")
        
        // Log what's currently stored
        os_log(.info, log: logger, "🔒 CURRENT STORED VALUES:")
        os_log(.info, log: logger, "  - lockScreenStoredPosition: %.2f", lockScreenStoredPosition)
        os_log(.info, log: logger, "  - lockScreenWasPlaying: %{public}s", lockScreenWasPlaying ? "YES" : "NO")
        os_log(.info, log: logger, "  - lockScreenStoredTimestamp: %{public}s",
               lockScreenStoredTimestamp?.description ?? "nil")
        
        guard let storedTime = lockScreenStoredTimestamp else {
            os_log(.info, log: logger, "🔒 RECOVERY REJECTED - No stored timestamp")
            return (0.0, false, false)
        }
        
        // Only valid if stored recently (within 10 minutes)
        let timeSinceStorage = Date().timeIntervalSince(storedTime)
        guard timeSinceStorage < 600 else {
            os_log(.error, log: logger, "🔒 RECOVERY REJECTED - Position too old: %.0f seconds", timeSinceStorage)
            return (0.0, false, false)
        }
        
        // SIMPLIFIED: Always return the exact stored position - no estimation!
        os_log(.info, log: logger, "🔒 RECOVERY RETURNING:")
        os_log(.info, log: logger, "  - Position: %.2f", lockScreenStoredPosition)
        os_log(.info, log: logger, "  - Was playing: %{public}s", lockScreenWasPlaying ? "YES" : "NO")
        os_log(.info, log: logger, "  - Valid: YES")
        
        return (lockScreenStoredPosition, lockScreenWasPlaying, true)
    }

    // Add this method to clear stored position
    func clearStoredPosition() {
        lockScreenStoredPosition = 0.0
        lockScreenStoredTimestamp = nil
        lockScreenWasPlaying = false
        connectionLostTime = nil
        os_log(.info, log: logger, "🔒 Cleared stored lock screen position")
    }
    
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
    func updateTrackMetadata(title: String, artist: String, album: String, artworkURL: String? = nil, duration: TimeInterval = 0.0) {
        os_log(.info, log: logger, "🎵 Updating track metadata: %{public}s - %{public}s (%.0f sec)", title, artist, duration)
        
        currentTrackTitle = title
        currentArtist = artist
        currentAlbum = album
        metadataDuration = duration
        
        // Load artwork if URL provided
        if let artworkURL = artworkURL, let url = URL(string: artworkURL) {
            loadArtwork(from: url)
        } else {
            currentArtwork = nil
            // Update immediately without artwork
            let (currentTime, isPlaying, _) = getCurrentPlaybackInfo()
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
                    let (currentTime, isPlaying, _) = self.getCurrentPlaybackInfo()
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
    
    // MARK: - Backward Compatibility Methods (keeping existing interface)
    func updatePlaybackState(isPlaying: Bool, currentTime: Double) {
        // SIMPLIFIED: Always update but with throttling
        let timeDifference = abs(currentTime - lastKnownAudioTime)
        
        // Only update if there's a meaningful time change (2+ seconds)
        if timeDifference > 2.0 {
            lastKnownAudioTime = currentTime
            updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
            os_log(.debug, log: logger, "📍 Updated from audio manager: %.2f (state: %{public}s)",
                   currentTime, isPlaying ? "playing" : "paused")
        }
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
        currentTrackTitle = "LMS Stream"
        currentArtist = "Unknown Artist"
        currentAlbum = "Lyrion Music Server"
        currentArtwork = nil
        metadataDuration = 0.0
        lastKnownServerTime = 0.0
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
        let (currentTime, isPlaying, source) = getCurrentPlaybackInfo()
        let serverStatus = serverTimeSynchronizer?.syncStatus ?? "No synchronizer"
        
        // Simplified debug info - only show key information
        return """
        Time: \(String(format: "%.1f", currentTime))s (\(source.description))
        Playing: \(isPlaying ? "Yes" : "No")
        Server: \(serverStatus)
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

// MARK: - ServerTimeSynchronizerDelegate
extension NowPlayingManager: ServerTimeSynchronizerDelegate {
    
    func serverTimeDidUpdate(currentTime: Double, duration: Double, isPlaying: Bool) {
        // Server time is our primary source, so update immediately
        lastKnownServerTime = currentTime
        
        // Update duration if we got one from server and don't have metadata duration
        if duration > 0 && metadataDuration <= 0 {
            metadataDuration = duration
            // Only log when we first get the duration, not every update
            os_log(.info, log: logger, "📍 Track duration set from server: %.0f seconds", duration)
        }
        
        // Update now playing info with server time
        updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
        
        os_log(.debug, log: logger, "📍 Updated from server time: %.2f/%.2f (%{public}s)",
               currentTime, duration, isPlaying ? "playing" : "paused")
    }
    
    func serverTimeFetchFailed(error: Error) {
        os_log(.error, log: logger, "⚠️ Server time fetch failed: %{public}s", error.localizedDescription)
        
        // Fall back to audio manager time
        if let audioManager = audioManager {
            let audioTime = audioManager.getCurrentTime()
            let isPlaying = audioManager.getPlayerState() == "Playing"
            lastKnownAudioTime = audioTime
            updateNowPlayingInfo(isPlaying: isPlaying, currentTime: audioTime)
            os_log(.info, log: logger, "🔄 Fell back to audio manager time: %.2f", audioTime)
        }
    }
    
    func serverTimeConnectionRestored() {
        os_log(.info, log: logger, "✅ Server time connection restored")
        
        // Immediately request updated time
        if let synchronizer = serverTimeSynchronizer {
            let serverInfo = synchronizer.getCurrentInterpolatedTime()
            if serverInfo.isServerTime {
                lastKnownServerTime = serverInfo.time
                updateNowPlayingInfo(isPlaying: serverInfo.isPlaying, currentTime: serverInfo.time)
                os_log(.info, log: logger, "🔄 Restored to server time: %.2f", serverInfo.time)
            }
        }
    }
}
