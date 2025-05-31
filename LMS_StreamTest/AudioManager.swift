import Foundation
import MobileVLCKit  // Using MobileVLCKit as you specified
import AVFoundation
import os.log

class AudioManager: NSObject, ObservableObject {
    private var mediaPlayer: VLCMediaPlayer!
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioManager")
    
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
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth, .allowAirPlay])
            try audioSession.setActive(true)
            os_log(.info, log: logger, "Audio session configured")
        } catch {
            os_log(.error, log: logger, "Audio session setup failed: %{public}s", error.localizedDescription)
        }
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
        return timeInSeconds
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
