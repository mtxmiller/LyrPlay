import Foundation
import MobileVLCKit  // Using MobileVLCKit as specified
import AVFoundation
import MediaPlayer  // Missing import for MPNowPlayingInfoCenter and MPRemoteCommandCenter
import os.log

class AudioManager: NSObject, ObservableObject {
    private var mediaPlayer: VLCMediaPlayer!
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioManager")
    private var lastReportedTime: Double = 0
    private var timeStuckCount = 0
    
    // Callback for when track ends
    var onTrackEnded: (() -> Void)?
    
    override init() {
        super.init()
        setupVLC()
        setupAudioSession()
    }
    
    private func setupVLC() {
        mediaPlayer = VLCMediaPlayer()
        os_log(.info, log: logger, "VLC MediaPlayer initialized (VLCKit 3.6.0)")
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Configure for background playback
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay, .defaultToSpeaker])
            try audioSession.setActive(true)
            os_log(.info, log: logger, "Audio session configured for background playback")
            
            // Set up now playing info center and remote commands
            setupNowPlayingInfo()
            setupRemoteCommandCenter()
        } catch {
            os_log(.error, log: logger, "Failed to setup audio session: %{public}s", error.localizedDescription)
        }
    }
    
    private func setupNowPlayingInfo() {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = "LMS Stream"
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Unknown Artist"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Lyrion Music Server"
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = 0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        os_log(.info, log: logger, "Now Playing info configured")
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Enable the commands you want to support
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        
        // Add handlers for the commands
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
        
        // Note: Next/Previous would need to communicate with LMS server
        commandCenter.nextTrackCommand.addTarget { _ in
            // Would need to send command to LMS server
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { _ in
            // Would need to send command to LMS server
            return .success
        }
        
        os_log(.info, log: logger, "Remote command center configured")
    }
    
    func playStream(urlString: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "Playing FLAC stream with VLC: %{public}s", urlString)
        
        // Create VLC media and play
        let media = VLCMedia(url: url)
        mediaPlayer.media = media
        mediaPlayer.play()
        
        // Update now playing info
        updateNowPlayingInfo(isPlaying: true)
        
        os_log(.info, log: logger, "VLC playback started")
    }
    
    func play() {
        mediaPlayer.play()
        updateNowPlayingInfo(isPlaying: true)
        os_log(.info, log: logger, "VLC resumed playback")
    }
    
    func pause() {
        mediaPlayer.pause()
        updateNowPlayingInfo(isPlaying: false)
        os_log(.info, log: logger, "VLC paused playback")
    }
    
    func stop() {
        mediaPlayer.stop()
        updateNowPlayingInfo(isPlaying: false)
        os_log(.info, log: logger, "VLC stopped playback")
    }
    
    func getCurrentTime() -> Double {
        // Get current playback time from VLC in seconds
        let vlcTime = mediaPlayer.time
        
        // Check if VLC has valid time data
        if vlcTime.intValue < 0 {
            // VLC returns -1 when time is not available
            return 0.0
        }
        
        let timeInSeconds = Double(vlcTime.intValue) / 1000.0
        let playerState = mediaPlayer.state
        
        // Check if time seems stuck (for debugging and end detection)
        if abs(timeInSeconds - lastReportedTime) < 0.1 && timeInSeconds > 0 {
            timeStuckCount += 1
            if timeStuckCount == 5 {
                os_log(.error, log: logger, "⚠️ VLC time stuck at %.2f seconds, state: %{public}s", timeInSeconds, vlcStateDescription(playerState))
            }
            
            // If time is stuck AND VLC state suggests end of playback
            if timeStuckCount >= 15 && (playerState == .ended || playerState == .stopped || !mediaPlayer.isPlaying) {
                os_log(.info, log: logger, "🎵 Detected track end via stuck time + VLC state - notifying server")
                timeStuckCount = 0
                lastReportedTime = 0
                DispatchQueue.main.async {
                    self.onTrackEnded?()
                }
                return timeInSeconds // Return the stuck time, don't reset to 0
            }
        } else {
            timeStuckCount = 0
        }
        lastReportedTime = timeInSeconds
        
        return timeInSeconds
    }
    
    func checkIfTrackEnded() -> Bool {
        let playerState = mediaPlayer.state
        let isPlaying = mediaPlayer.isPlaying
        
        os_log(.debug, log: logger, "Manual track end check - State: %{public}s, Playing: %{public}s",
               vlcStateDescription(playerState), isPlaying ? "YES" : "NO")
        
        if playerState == .ended || (timeStuckCount > 10 && !isPlaying) {
            os_log(.info, log: logger, "🎵 Manual check detected track end")
            return true
        }
        
        return false
    }
    
    private func updateNowPlayingInfo(isPlaying: Bool) {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        
        // Update playback state
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = getCurrentTime()
        
        // Get duration from VLC if available
        if let media = mediaPlayer.media {
            let duration = media.length
            if duration.intValue > 0 {
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(duration.intValue) / 1000.0
            }
        }
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }
    
    func getPlayerState() -> VLCMediaPlayerState {
        return mediaPlayer.state
    }
    
    func getDuration() -> Double {
        // Get total duration from VLC
        guard let media = mediaPlayer.media else { return 0.0 }
        let duration = media.length
        if duration.intValue < 0 {
            return 0.0
        }
        return Double(duration.intValue) / 1000.0
    }
    
    func getPosition() -> Float {
        // Get playback position as 0.0 to 1.0
        return mediaPlayer.position
    }
    
    private func vlcStateDescription(_ state: VLCMediaPlayerState) -> String {
        switch state {
        case .stopped: return "Stopped"
        case .opening: return "Opening"
        case .buffering: return "Buffering"
        case .ended: return "Ended"
        case .error: return "Error"
        case .playing: return "Playing"
        case .paused: return "Paused"
        @unknown default: return "Unknown(\(state.rawValue))"
        }
    }
    
    deinit {
        stop()
    }
}

// MARK: - VLCMediaPlayerDelegate
extension AudioManager: VLCMediaPlayerDelegate {
    
    // This delegate method might not be called reliably, using NotificationCenter instead
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        // Implementation can be added here if needed for more reactive state handling
        let playerState = mediaPlayer.state
        os_log(.debug, log: logger, "VLC state changed to: %{public}s", vlcStateDescription(playerState))
        
        if playerState == .ended {
            os_log(.info, log: logger, "🎵 VLC reported track ended via delegate")
            DispatchQueue.main.async {
                self.onTrackEnded?()
            }
        }
    }
}
