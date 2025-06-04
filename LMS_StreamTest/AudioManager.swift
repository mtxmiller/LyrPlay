// File: AudioManager.swift (Refactored)
// Coordinator that manages all audio components while preserving the exact same public interface
import Foundation
import os.log

class AudioManager: NSObject, ObservableObject {
    
    // MARK: - Components
    private let audioPlayer: AudioPlayer
    private let audioSessionManager: AudioSessionManager
    private let nowPlayingManager: NowPlayingManager
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioManager")
    
    // MARK: - Public Interface (Preserved from Original)
    var onTrackEnded: (() -> Void)?
    var slimClient: SlimProtoCoordinator?  // Changed from weak to strong reference
    
    // MARK: - Initialization
    override init() {
        self.audioPlayer = AudioPlayer()
        self.audioSessionManager = AudioSessionManager()
        self.nowPlayingManager = NowPlayingManager()
        
        super.init()
        
        setupDelegation()
        os_log(.info, log: logger, "✅ Refactored AudioManager initialized with modular architecture")
    }
    
    // MARK: - Component Integration
    private func setupDelegation() {
        // Connect AudioPlayer to AudioManager
        audioPlayer.delegate = self
        
        // Connect AudioSessionManager to AudioManager
        audioSessionManager.delegate = self
        
        // Connect NowPlayingManager to AudioManager
        nowPlayingManager.delegate = self
        
        os_log(.info, log: logger, "✅ Component delegation configured")
    }
    
    // MARK: - Public Interface (Exact same as original AudioManager)
    
    // Stream playback methods
    func playStream(urlString: String) {
        audioPlayer.playStream(urlString: urlString)
    }
    
    func playStreamWithFormat(urlString: String, format: String) {
        // Configure audio session based on format
        configureAudioSessionForFormat(format)
        
        // Start playback
        audioPlayer.playStreamWithFormat(urlString: urlString, format: format)
    }
    
    func playStreamAtPosition(urlString: String, startTime: Double) {
        audioPlayer.playStreamAtPosition(urlString: urlString, startTime: startTime)
    }
    
    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String) {
        // Configure audio session based on format
        configureAudioSessionForFormat(format)
        
        // Start playback
        audioPlayer.playStreamAtPositionWithFormat(urlString: urlString, startTime: startTime, format: format)
    }
    
    // Playback control
    func play() {
        audioPlayer.play()
    }
    
    func pause() {
        audioPlayer.pause()
    }
    
    func stop() {
        audioPlayer.stop()
    }
    
    // State queries
    func getCurrentTime() -> Double {
        return audioPlayer.getCurrentTime()
    }
    
    func getDuration() -> Double {
        return audioPlayer.getDuration()
    }
    
    func getPosition() -> Float {
        return audioPlayer.getPosition()
    }
    
    func getPlayerState() -> String {
        return audioPlayer.getPlayerState()
    }
    
    func checkIfTrackEnded() -> Bool {
        // Delegate to player for consistency
        let currentTime = audioPlayer.getCurrentTime()
        let duration = audioPlayer.getDuration()
        
        if duration > 0 && currentTime >= duration - 0.5 {
            return true
        }
        
        return false
    }
    
    // Metadata management
    func updateTrackMetadata(title: String, artist: String, album: String, artworkURL: String? = nil, duration: TimeInterval = 0.0) {
        // Update both the player and now playing manager
        audioPlayer.setMetadataDuration(duration)
        nowPlayingManager.updateTrackMetadata(
            title: title,
            artist: artist,
            album: album,
            artworkURL: artworkURL,
            duration: duration
        )
        
        os_log(.info, log: logger, "🎵 Updated track metadata: %{public}s - %{public}s", title, artist)
    }
    
    // MARK: - Private Audio Session Configuration
    private func configureAudioSessionForFormat(_ format: String) {
        switch format.uppercased() {
        case "ALAC", "FLAC":
            audioSessionManager.setupForLosslessAudio()
        case "AAC", "MP3":
            audioSessionManager.setupForCompressedAudio()
        default:
            audioSessionManager.setupForCompressedAudio()
        }
    }
    
    // MARK: - Lock Screen Integration (Preserved Interface)
    func setSlimClient(_ slimClient: SlimProtoCoordinator) {
        os_log(.info, log: logger, "🔗 AudioManager.setSlimClient called")
        self.slimClient = slimClient
        nowPlayingManager.setSlimClient(slimClient)
        os_log(.info, log: logger, "✅ SlimClient reference set for AudioManager and NowPlayingManager")
    }
    
    // MARK: - Cleanup
    deinit {
        os_log(.info, log: logger, "Refactored AudioManager deinitialized")
    }
}

// MARK: - AudioPlayerDelegate
extension AudioManager: AudioPlayerDelegate {
    
    func audioPlayerDidStartPlaying() {
        os_log(.info, log: logger, "▶️ Audio player started playing")
        
        // Update now playing info
        let currentTime = audioPlayer.getCurrentTime()
        nowPlayingManager.updatePlaybackState(isPlaying: true, currentTime: currentTime)
    }
    
    func audioPlayerDidPause() {
        os_log(.info, log: logger, "⏸️ Audio player paused")
        
        // Update now playing info
        let currentTime = audioPlayer.getCurrentTime()
        nowPlayingManager.updatePlaybackState(isPlaying: false, currentTime: currentTime)
    }
    
    func audioPlayerDidStop() {
        os_log(.info, log: logger, "⏹️ Audio player stopped")
        
        // Update now playing info
        nowPlayingManager.updatePlaybackState(isPlaying: false, currentTime: 0.0)
    }
    
    func audioPlayerDidReachEnd() {
        os_log(.info, log: logger, "🎵 Track ended - notifying coordinator")
        
        // Call the original callback
        onTrackEnded?()
    }
    
    func audioPlayerTimeDidUpdate(_ time: Double) {
        // Update now playing info with current time
        let isPlaying = audioPlayer.getPlayerState() == "Playing"
        nowPlayingManager.updatePlaybackState(isPlaying: isPlaying, currentTime: time)
    }
    
    func audioPlayerDidStall() {
        os_log(.error, log: logger, "⚠️ Audio player stalled")
        
        // Could add retry logic here in the future
    }
}

// MARK: - AudioSessionManagerDelegate
extension AudioManager: AudioSessionManagerDelegate {
    
    func audioSessionDidEnterBackground() {
        os_log(.info, log: logger, "📱 Audio session entered background")
        
        // Could add background-specific logic here
        // For now, the audio session manager handles the background task
    }
    
    func audioSessionDidEnterForeground() {
        os_log(.info, log: logger, "📱 Audio session entered foreground")
        
        // Could add foreground-specific logic here
        // Update now playing info to ensure it's current
        let currentTime = audioPlayer.getCurrentTime()
        let isPlaying = audioPlayer.getPlayerState() == "Playing"
        nowPlayingManager.updatePlaybackState(isPlaying: isPlaying, currentTime: currentTime)
    }
}

// MARK: - NowPlayingManagerDelegate
extension AudioManager: NowPlayingManagerDelegate {
    
    func nowPlayingDidReceivePlayCommand() {
        // NOTE: Not used - lock screen commands go directly to server
        os_log(.debug, log: logger, "🎵 Lock screen play command (unused)")
    }
    
    func nowPlayingDidReceivePauseCommand() {
        // NOTE: Not used - lock screen commands go directly to server
        os_log(.debug, log: logger, "⏸️ Lock screen pause command (unused)")
    }
    
    func nowPlayingDidReceiveNextTrackCommand() {
        // NOTE: Not used - lock screen commands go directly to server
        os_log(.debug, log: logger, "⏭️ Lock screen next track command (unused)")
    }
    
    func nowPlayingDidReceivePreviousTrackCommand() {
        // NOTE: Not used - lock screen commands go directly to server
        os_log(.debug, log: logger, "⏮️ Lock screen previous track command (unused)")
    }
}

// MARK: - Debug and Utility Methods
extension AudioManager {
    
    func logDetailedState() {
        os_log(.info, log: logger, "🔍 AudioManager State:")
        os_log(.info, log: logger, "  Player State: %{public}s", getPlayerState())
        os_log(.info, log: logger, "  Current Time: %.2f", getCurrentTime())
        os_log(.info, log: logger, "  Duration: %.2f", getDuration())
        os_log(.info, log: logger, "  Position: %.2f", getPosition())
        os_log(.info, log: logger, "  Track: %{public}s - %{public}s",
               nowPlayingManager.getCurrentTrackTitle(),
               nowPlayingManager.getCurrentArtist())
        
        // Log audio session state
        audioSessionManager.logCurrentAudioSessionState()
    }
    
    func getCurrentAudioRoute() -> String {
        return audioSessionManager.getCurrentAudioRoute()
    }
    
    func isOtherAudioPlaying() -> Bool {
        return audioSessionManager.isOtherAudioPlaying()
    }
}
// MARK: - Server Time Integration
extension AudioManager {
    
    /// Sets up server time synchronization for accurate lock screen timing
    /// This method should be called by SlimProtoCoordinator after connection
    func setupServerTimeIntegration(with synchronizer: ServerTimeSynchronizer) {
        // Connect the synchronizer to our NowPlayingManager
        nowPlayingManager.setServerTimeSynchronizer(synchronizer)
        nowPlayingManager.setAudioManager(self)
        
        os_log(.info, log: logger, "✅ Server time integration configured for AudioManager")
    }
    
    /// Gets time source information for debugging
    func getTimeSourceInfo() -> String {
        return nowPlayingManager.getTimeSourceInfo()
    }
    
    /// Gets server time synchronization status for debugging
    func getServerTimeStatus() -> String {
        return nowPlayingManager.getTimeSourceInfo()
    }
}
