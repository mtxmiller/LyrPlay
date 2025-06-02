// File: NowPlayingManager.swift
// Lock screen controls, metadata display, and remote command handling
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
    
    // MARK: - Delegation
    weak var delegate: NowPlayingManagerDelegate?
    
    // MARK: - Lock Screen Command Reference
    weak var slimClient: SlimProtoCoordinator?
    
    // MARK: - Initialization
    init() {
        setupNowPlayingInfo()
        setupRemoteCommandCenter()
        os_log(.info, log: logger, "NowPlayingManager initialized")
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
            updateNowPlayingInfo(isPlaying: false) // Update immediately without artwork
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
                self?.updateNowPlayingInfo(isPlaying: false)
            }
        }.resume()
    }
    
    // MARK: - Now Playing Info Updates
    func updateNowPlayingInfo(isPlaying: Bool, currentTime: Double = 0.0) {
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
            os_log(.debug, log: logger, "🔍 Setting playback duration to %.0f seconds from metadata", metadataDuration)
        } else {
            // For live streams, remove duration info
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            os_log(.debug, log: logger, "🔍 Live stream detected - removing duration info")
        }
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        
        // Debug logging
        if let duration = nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? TimeInterval {
            os_log(.debug, log: logger, "🔍 Now Playing: %.0f/%.0f seconds, rate: %.1f",
                   currentTime, duration, isPlaying ? 1.0 : 0.0)
        }
    }
    
    func updatePlaybackState(isPlaying: Bool, currentTime: Double) {
        updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
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
    
    // MARK: - Cleanup
    deinit {
        clearNowPlayingInfo()
        enableRemoteCommands(false)
        os_log(.info, log: logger, "NowPlayingManager deinitialized")
    }
    
}
