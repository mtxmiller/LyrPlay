import Foundation
import MobileVLCKit  // Using MobileVLCKit as you specified
import AVFoundation
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
            // Configure for background playbook
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay, .defaultToSpeaker])
            try audioSession.setActive(true)
            os_log(.info, log: logger, "Audio session configured for background playback")
            
            // Set up now playing info center
            // setupNowPlayingInfo() // Temporarily commented out
        } catch {
            os_log(.error, log: logger, "Failed to setup audio session: %{public}s", error.localizedDescription)
        }
    }
    
    private func setupNowPlayingInfo() {
        // Temporarily comment out this method until MediaPlayer import issue is resolved
        /*
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = "LMS Stream"
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Unknown Artist"
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = 0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        */
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
        
        os_log(.info, log: logger, "VLC playback started")
    }
    
    func play() {
        mediaPlayer.play()
        os_log(.info, log: logger, "VLC resumed playback")
    }
    
    func pause() {
        mediaPlayer.pause()
        os_log(.info, log: logger, "VLC paused playback")
    }
    
    func stop() {
        mediaPlayer.stop()
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
    
    private func stateDescription(_ state: VLCMediaPlayerState) -> String {
        switch state {
        case .stopped:
            return "Stopped"
        case .opening:
            return "Opening"
        case .buffering:
            return "Buffering"
        case .ended:
            return "Ended"
        case .error:
            return "Error"
        case .playing:
            return "Playing"
        case .paused:
            return "Paused"
        @unknown default:
            return "Unknown(\(state.rawValue))"
        }
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
    
    deinit {
        stop()
    }
}

// MARK: - VLCMediaPlayerDelegate
extension AudioManager: VLCMediaPlayerDelegate {
    
    // This delegate method might not be called reliably, using NotificationCenter instead
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        // Implementation moved to @objc method above
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
}
