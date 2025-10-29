// File: AudioManager.swift (Refactored)
// Coordinator that manages all audio components while preserving the exact same public interface
import Foundation
import AVFoundation
import os.log

class AudioManager: NSObject, ObservableObject {
    
    static let shared = AudioManager()  // ← ADD THIS LINE
    
    // MARK: - Components
    private let audioPlayer: AudioPlayer
    private let audioSessionManager: AudioSessionManager
    private let nowPlayingManager: NowPlayingManager
    private let streamDecoder: AudioStreamDecoder  // NEW: For gapless playback
    
    // MARK: - Time Update Throttling (ADD THIS LINE)
    private var lastTimeUpdateReport: Date = Date()
    private let minimumTimeUpdateInterval: TimeInterval = 2.0  // Max update every 2 seconds
    
    weak var commandHandler: SlimProtoCommandHandler?
    
    
    // NEW: Expose NowPlayingManager for coordinator access
    func getNowPlayingManager() -> NowPlayingManager {
        return nowPlayingManager
    }
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioManager")
    
    // MARK: - Public Interface (Preserved from Original)
    var onTrackEnded: (() -> Void)?
    var slimClient: SlimProtoCoordinator?  // Changed from weak to strong reference
    
    private var wasPlayingBeforeInterruption: Bool = false
    private var interruptionPosition: Double = 0.0
    
    
    // MARK: - Initialization
    private override init() {
        self.audioPlayer = AudioPlayer()
        self.audioSessionManager = AudioSessionManager()
        self.nowPlayingManager = NowPlayingManager()
        self.streamDecoder = AudioStreamDecoder()  // NEW: Initialize decoder

        super.init()

        setupDelegation()

        // CRITICAL: Ensure NowPlayingManager gets AudioManager reference for fallback timing
        nowPlayingManager.setAudioManager(self)

        PlaybackSessionController.shared.configure(audioManager: self) { [weak self] in
            self?.slimClient
        }

        os_log(.info, log: logger, "✅ AudioManager initialized with lock screen controls ready")
    }
    
    // MARK: - Component Integration
    private func setupDelegation() {
        // Connect AudioPlayer to AudioManager
        audioPlayer.delegate = self
        audioPlayer.audioManager = self  // Set back-reference for media control refresh

        // Connect AudioSessionManager to AudioManager - ENHANCED
        audioSessionManager.delegate = self

        // Connect AudioStreamDecoder to AudioManager - NEW
        streamDecoder.delegate = self

        os_log(.info, log: logger, "✅ Component delegation configured with interruption handling and gapless decoder")
    }
    
    func setCommandHandler(_ handler: SlimProtoCommandHandler) {
        commandHandler = handler
        audioPlayer.commandHandler = handler
    }
    

    
    
    // MARK: - Public Interface (Exact same as original AudioManager)
    
    // Stream playback methods
    func playStreamWithFormat(urlString: String, format: String, replayGain: Float = 0.0) {
        // Configure audio session based on format
        configureAudioSessionForFormat(format)

        // Start playback
        activateAudioSession()
        audioPlayer.playStreamWithFormat(urlString: urlString, format: format, replayGain: replayGain)
    }

    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String, replayGain: Float = 0.0) {
        // Configure audio session based on format
        configureAudioSessionForFormat(format)

        // Start playback
        activateAudioSession()
        audioPlayer.playStreamAtPositionWithFormat(urlString: urlString, startTime: startTime, format: format, replayGain: replayGain)
    }

    // NEW: Push stream playback for gapless
    func startPushStreamPlayback(format: String, sampleRate: Int = 44100, channels: Int = 2, replayGain: Float = 0.0) {
        os_log(.info, log: logger, "📊 Starting push stream playback: %{public}s @ %dHz", format, sampleRate)

        // Configure audio session
        configureAudioSessionForFormat(format)
        activateAudioSession()

        // Initialize push stream
        streamDecoder.initializePushStream(sampleRate: sampleRate, channels: channels)

        // Start playback
        if streamDecoder.startPlayback() {
            os_log(.info, log: logger, "✅ Push stream playback started successfully")
        } else {
            os_log(.error, log: logger, "❌ Failed to start push stream playback")
        }
    }

    func stopPushStreamPlayback() {
        os_log(.info, log: logger, "🛑 Stopping push stream playback")
        streamDecoder.cleanup()
    }

    // Playback control
    func play() {
        activateAudioSession()
        audioPlayer.play()
    }
    
    func pause() {
        audioPlayer.pause()
    }
    
    func stop() {
        audioPlayer.stop()
    }
    
    // State queries
    // DEPRECATED: Do not use AudioPlayer time for server operations
    // Use slimClient.getCurrentInterpolatedTime().time instead
    // func getCurrentTime() -> Double {
    //     return audioPlayer.getCurrentTime()
    // }

    /// INTERNAL FALLBACK ONLY: Get AudioPlayer time when server time unavailable
    /// This should only be used by NowPlayingManager as last resort fallback
    internal func getAudioPlayerTimeForFallback() -> Double {
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
    
    // MARK: - Volume Control
    func setVolume(_ volume: Float) {
        audioPlayer.setVolume(volume)
    }

    func getVolume() -> Float {
        return audioPlayer.getVolume()
    }

    // MARK: - Silent Recovery Support
    /// Enable silent mode for the next stream (for app foreground recovery)
    func enableSilentRecoveryMode() {
        audioPlayer.muteNextStream = true
    }

    /// Disable silent mode and restore normal DSP gain
    func disableSilentRecoveryMode() {
        audioPlayer.muteNextStream = false
        audioPlayer.restoreDSPGain()
    }

    func activateAudioSession(context: PlaybackSessionController.ActivationContext = .userInitiatedPlay) {
        // BASS automatically manages iOS audio session - no manual activation needed
        os_log(.info, log: logger, "🔒 Audio session activation (BASS auto-managed - no action needed)")
    }
    
    // Metadata management
    func updateTrackMetadata(title: String, artist: String, album: String, artworkURL: String? = nil, duration: TimeInterval? = nil) {
        // Only update duration if explicitly provided (Material skin approach)
        if let duration = duration {
            audioPlayer.setMetadataDuration(duration)
            os_log(.info, log: logger, "🎵 Updated track metadata: %{public}s - %{public}s (%.0f sec)", title, artist, duration)
        } else {
            os_log(.info, log: logger, "🎵 Updated track metadata: %{public}s - %{public}s", title, artist)
        }
        
        // Update now playing manager
        nowPlayingManager.updateTrackMetadata(
            title: title,
            artist: artist,
            album: album,
            artworkURL: artworkURL,
            duration: duration  // Pass through optional duration
        )
    }
    
    // MARK: - Private Audio Session Configuration
    private func configureAudioSessionForFormat(_ format: String) {
        // DISABLED: Format-specific audio session configuration
        // BASS now handles AVAudioSession exclusively via BASS_CONFIG_IOS_SESSION
        // This prevents conflicts and error -50

        os_log(.info, log: logger, "🎵 Format: %{public}s - BASS handles audio session automatically", format)

        /*
        switch format.uppercased() {
        case "ALAC", "FLAC":
            audioSessionManager.setupForLosslessAudio()
        case "AAC", "MP3":
            audioSessionManager.setupForCompressedAudio()
        default:
            audioSessionManager.setupForCompressedAudio()
        }
        */
    }
    
    // MARK: - Lock Screen Integration (Preserved Interface)
    func setSlimClient(_ slimClient: SlimProtoCoordinator) {
        os_log(.info, log: logger, "🔗 AudioManager.setSlimClient called")
        self.slimClient = slimClient
        nowPlayingManager.setSlimClient(slimClient)
        os_log(.info, log: logger, "✅ SlimClient reference set for AudioManager and NowPlayingManager")
    }

    // MARK: - Route Change Handling (Required by AudioPlaybackControlling protocol)
    /// BASS automatically handles iOS audio route changes - no action needed
    func handleAudioRouteChange() {
        os_log(.info, log: logger, "🔀 Route change - BASS manages automatically")
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
        
        // FORWARD TO COORDINATOR: This is the missing piece!
        // When AudioPlayer actually starts playing, tell the coordinator to send STMs
        slimClient?.handleAudioPlayerDidStartPlaying()
        
        // SIMPLIFIED: Just log the event, let the existing timer/update mechanisms handle position updates
        os_log(.debug, log: logger, "📍 Audio start event logged")
    }
    
    func audioPlayerDidPause() {
        os_log(.info, log: logger, "⏸️ Audio player paused")
        
        // DON'T use audio player time - it can be wrong/stale
        // Let the server time synchronizer handle position tracking
        let audioTime = audioPlayer.getCurrentTime()
        os_log(.info, log: logger, "🔒 Audio player reports pause time: %.2f (NOT using - server is master)", audioTime)
        
        // Update playing state only, let server time synchronizer provide the position
        nowPlayingManager.updatePlaybackState(isPlaying: false, currentTime: 0.0)
    }
    
    func audioPlayerDidStop() {
        os_log(.debug, log: logger, "⏹️ Audio player stopped")
        
        // Update now playing info
        nowPlayingManager.updatePlaybackState(isPlaying: false, currentTime: 0.0)
    }
    
    func audioPlayerDidReachEnd() {
        os_log(.info, log: logger, "🎵 Track ended - notifying coordinator")
        
        // Call the original callback
        onTrackEnded?()
    }
    
    func audioPlayerTimeDidUpdate(_ time: Double) {
        // REMOVED: All time update reporting and throttling
        // The server is the master - don't spam it with position updates
        
        // Only update now playing info locally, don't send to server
        let isPlaying = audioPlayer.getPlayerState() == "Playing"
        nowPlayingManager.updatePlaybackState(isPlaying: isPlaying, currentTime: time)
        
        // REMOVED: All the complicated throttling and server communication
        os_log(.debug, log: logger, "📍 Local time update only: %.2f", time)
    }

    
    func audioPlayerDidStall() {
        os_log(.error, log: logger, "⚠️ Audio player stalled")

        // Could add retry logic here in the future
    }

    func audioPlayerRequestsSeek(_ timeOffset: Double) {
        os_log(.info, log: logger, "🔧 Audio player requested seek to %{public}.2f seconds (transcoding fallback disabled)", timeOffset)
        // Intentionally no-op: rely on larger BASS verification window instead of server seek
    }
    
    func audioPlayerDidReceiveMetadataUpdate() {
        os_log(.info, log: logger, "🎵 Audio player detected metadata update - requesting fresh metadata")

        // Notify the coordinator to fetch fresh metadata
        if let slimClient = slimClient {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Request fresh metadata from server
                slimClient.requestFreshMetadata()
            }
        }
    }

    func audioPlayerDidReceiveMetadata(_ metadata: (title: String?, artist: String?)) {
        // Forward ICY metadata to SlimProto coordinator (logging handled there)
        slimClient?.handleICYMetadata(metadata)
    }
}

// MARK: - Interruption State Management
extension AudioManager {

    // MARK: - Public Interruption Status
    func getInterruptionStatus() -> String {
        return audioSessionManager.getInterruptionStatus()
    }
}

// MARK: - AudioSessionManagerDelegate
extension AudioManager: AudioSessionManagerDelegate {
    
    func audioSessionDidEnterBackground() {
        os_log(.info, log: logger, "📱 Audio session entered background")
        // Existing background logic...
    }
    
    func audioSessionDidEnterForeground() {
        os_log(.info, log: logger, "📱 Audio session entered foreground")
        
        // Existing foreground logic...
        // FIXED: Use server time for lock screen consistency
        let currentTime: Double
        if let coordinator = slimClient {
            let interpolatedTime = coordinator.getCurrentInterpolatedTime()
            currentTime = interpolatedTime.time
        } else {
            currentTime = audioPlayer.getCurrentTime()  // Fallback
        }
        let isPlaying = audioPlayer.getPlayerState() == "Playing"
        nowPlayingManager.updatePlaybackState(isPlaying: isPlaying, currentTime: currentTime)
    }
    
    // AudioSessionManagerDelegate methods - PlaybackSessionController handles actual interruption logic
    func audioSessionWasInterrupted(shouldPause: Bool) {
        guard shouldPause else { return }
        let currentState = getPlayerState()
        wasPlayingBeforeInterruption = (currentState == "Playing")
        os_log(.info, log: logger, "🚫 Audio interrupted (PlaybackSessionController handles server commands)")
    }

    func audioSessionInterruptionEnded(shouldResume: Bool) {
        os_log(.info, log: logger, "✅ Interruption ended (PlaybackSessionController handles server commands)")
        wasPlayingBeforeInterruption = false
    }

    func audioSessionRouteChanged(shouldPause: Bool) {
        let routeChangeDescription = audioSessionManager.interruptionManager?.lastRouteChange?.description ?? "Unknown"
        os_log(.info, log: logger, "🔀 Route change: %{public}s (PlaybackSessionController handles server commands)", routeChangeDescription)
    }
}

// MARK: - Debug and Utility Methods
extension AudioManager {
    
    func logDetailedState() {
        os_log(.info, log: logger, "🔍 AudioManager State:")
        os_log(.info, log: logger, "  Player State: %{public}s", getPlayerState())
        os_log(.info, log: logger, "  Current Time: %.2f", getAudioPlayerTimeForFallback())
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
    /// Gets time source information for debugging
    func getTimeSourceInfo() -> String {
        return nowPlayingManager.getTimeSourceInfo()
    }
}

// MARK: - AudioStreamDecoder Delegate (NEW - Gapless Playback)
extension AudioManager: AudioStreamDecoderDelegate {
    func audioStreamDecoderNeedsMoreData(_ decoder: AudioStreamDecoder) {
        os_log(.debug, log: logger, "📊 Stream decoder needs more data - buffer low")
        // TODO: Request more data from SlimProto socket
        // This will be implemented when we hook up the socket reading
    }

    func audioStreamDecoderDidReachTrackBoundary(_ decoder: AudioStreamDecoder) {
        os_log(.info, log: logger, "🎯 Track boundary reached - gapless transition!")
        // Update Now Playing metadata for new track
        // TODO: Notify coordinator of track change when method is implemented
        // slimClient?.handleTrackBoundary()
    }
}
