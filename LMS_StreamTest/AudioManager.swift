// File: AudioManager.swift (Refactored)
// Coordinator that manages all audio components while preserving the exact same public interface
import Foundation
import AVFoundation
import os.log

class AudioManager: NSObject, ObservableObject {

    static let shared = AudioManager()  // ← ADD THIS LINE

    // MARK: - Components
    let audioPlayer: AudioPlayer  // Made public for SettingsView access
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

        #if DEBUG
        os_log(.info, log: logger, "✅ AudioManager initialized with lock screen controls ready")
        #endif
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
        streamDecoder.audioPlayer = audioPlayer  // Set reference for stream info updates

        #if DEBUG
        os_log(.info, log: logger, "✅ Component delegation configured with interruption handling and gapless decoder")
        #endif
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

    // NEW: Push stream playback for gapless (matches squeezelite architecture)
    func startPushStreamPlayback(url: String, format: String, sampleRate: Int = 44100, channels: Int = 2, replayGain: Float = 0.0, isGapless: Bool = false, startTime: Double = 0.0) {
        os_log(.info, log: logger, "📊 Starting push stream playback: %{public}s @ %dHz (gapless: %d)", format, sampleRate, isGapless)
        os_log(.debug, log: logger, "📊 Decoder URL: %{public}s", url)

        // Configure audio session
        configureAudioSessionForFormat(format)
        activateAudioSession()

        // Check if we need to initialize push stream (first time or after cleanup)
        let hasValidStream = streamDecoder.hasValidStream()

        if !hasValidStream {
            // First time: Create push stream
            os_log(.info, log: logger, "📊 Creating new push stream (first track)")
            streamDecoder.initializePushStream(sampleRate: sampleRate, channels: channels)

            // Start playback
            if streamDecoder.startPlayback() {
                os_log(.info, log: logger, "✅ Push stream playback started")
            } else {
                os_log(.error, log: logger, "❌ Failed to start push stream playback")
                return
            }
        } else if !isGapless {
            // Manual skip: Stop old decoder, flush buffer
            // But first ensure BASS output device is resumed after any route change
            os_log(.info, log: logger, "📊 Manual skip - stopping old decoder and flushing buffer")
            streamDecoder.stopDecoding()

            // CRITICAL: After route change, BASS device may be paused (BASS_ACTIVE_PAUSED_DEVICE)
            // Per BASS docs: "playback will be resumed by BASS_Start"
            // Ensure output device is active before flushing buffer
            BASS_Start()
            os_log(.info, log: logger, "🔊 Ensured BASS output device active before buffer flush")

            // Now safe to flush buffer - device is active and ready for new audio
            streamDecoder.flushBuffer()
        } else {
            // Gapless transition: DON'T flush buffer, let old audio finish playing
            // The decoder already stopped naturally (triggered this call via delegate)
            os_log(.info, log: logger, "🎵 Gapless transition - preserving buffer (old audio will finish)")
            // NO stopDecoding() - decoder already stopped naturally
            // NO flushBuffer() - we want old audio to keep playing!
        }

        // Start new decoder for this track
        // isNewTrack: true for gapless (mark boundary), false for manual skip (fresh start)
        // replayGain: Linear gain multiplier from server (applied via BASS_ATTRIB_VOLDSP)
        streamDecoder.startDecodingFromURL(url, format: format, isNewTrack: isGapless, startTime: startTime, replayGain: replayGain)

        os_log(.info, log: logger, "✅ Push stream decoder started (gapless: %d, startTime: %.2f, replayGain: %.4f)", isGapless, startTime, replayGain)
    }

    func stopPushStreamPlayback() {
        os_log(.info, log: logger, "🛑 Stopping push stream playback")
        streamDecoder.cleanup()
    }

    // Playback control
    func play() {
        activateAudioSession()

        // Control push stream or audio player depending on active mode
        if streamDecoder.hasValidStream() {
            streamDecoder.resumePlayback()
            os_log(.info, log: logger, "▶️ Resuming push stream playback")
        } else {
            audioPlayer.play()
        }
    }

    func pause() {
        // Control push stream or audio player depending on active mode
        if streamDecoder.hasValidStream() {
            streamDecoder.pausePlayback()
            os_log(.info, log: logger, "⏸️ Pausing push stream playback")
        } else {
            audioPlayer.pause()
        }
    }
    
    func stop() {
        // Stop traditional URL stream player
        audioPlayer.stop()

        // CRITICAL: Stop push stream decoder AND pause playback
        // When server sends stop 'q' command (manual skip or pause for radio streams):
        // 1. stopDecoding() sets manualStop = true, preventing gapless transition callback
        // 2. pausePlayback() immediately pauses BASS stream, stopping buffered audio
        // Without pausePlayback(), ~10 seconds of buffered audio continues playing
        streamDecoder.stopDecoding()
        streamDecoder.pausePlayback()

        os_log(.info, log: logger, "⏹️ Stopped decoder and paused stream playback")
    }

    // MARK: - PHASE 3: Synchronized Start for Multi-Room Audio

    /// Start playback at a specific jiffies time (for player synchronization)
    /// Buffers audio but delays playback until target jiffies time is reached
    func startAtJiffies(_ targetJiffies: TimeInterval) {
        os_log(.info, log: logger, "🎯 AudioManager routing synchronized start")

        // Activate audio session for playback
        activateAudioSession()

        // Route to appropriate player based on stream type
        if streamDecoder.hasValidStream() {
            // PHASE 7.2: Push streams now support synchronized start!
            os_log(.info, log: logger, "🎯 Routing to streamDecoder.startAtJiffies()")
            streamDecoder.startAtJiffies(targetJiffies)
        } else {
            // URL streams (legacy)
            audioPlayer.startAt(jiffies: targetJiffies)
        }
    }

    // MARK: - PHASE 4: Sync Drift Corrections

    /// Play silence for a duration (timed pause for sync drift correction)
    func playSilence(duration: TimeInterval) {
        os_log(.info, log: logger, "⏸️🔇 AudioManager routing play silence")

        // Route to appropriate player based on stream type
        if streamDecoder.hasValidStream() {
            // PHASE 7.3: Push streams now support silence injection!
            os_log(.info, log: logger, "🔇 Routing to streamDecoder.playSilence()")
            streamDecoder.playSilence(duration: duration)
        } else {
            // URL streams (legacy)
            audioPlayer.playSilence(duration: duration)
        }
    }

    /// Skip ahead by consuming buffer (sync drift correction)
    func skipAhead(duration: TimeInterval) {
        os_log(.info, log: logger, "⏩ AudioManager routing skip ahead")

        // Route to appropriate player based on stream type
        if streamDecoder.hasValidStream() {
            // PHASE 7.4: Push streams now support buffer skip ahead!
            os_log(.info, log: logger, "⏩ Routing to streamDecoder.skipAhead()")
            streamDecoder.skipAhead(duration: duration)
        } else {
            // URL streams (legacy)
            audioPlayer.skipAhead(duration: duration)
        }
    }

    // State queries
    // DEPRECATED: Do not use AudioPlayer time for server operations
    // Use slimClient.getCurrentInterpolatedTime().time instead
    // func getCurrentTime() -> Double {
    //     return audioPlayer.getCurrentTime()
    // }

    /// INTERNAL FALLBACK ONLY: Get AudioPlayer time when server time unavailable
    /// This should only be used by NowPlayingManager as last resort fallback
    /// UPDATED: For push streams, report decoded position (like squeezelite reports frames_played)
    internal func getAudioPlayerTimeForFallback() -> Double {
        // For push streams, report our decoded position (bytes pushed / bytes per second)
        // This matches squeezelite reporting frames_played / sample_rate
        if streamDecoder.isPlaying() {
            return streamDecoder.getCurrentPosition()
        }
        // For URL streams, use audio player position
        return audioPlayer.getCurrentTime()
    }
    
    func getDuration() -> Double {
        return audioPlayer.getDuration()
    }
    
    func getPosition() -> Float {
        // Use decoder position for push streams, audio player position for URL streams
        if streamDecoder.isPlaying() {
            return Float(streamDecoder.getCurrentPosition())
        }
        return audioPlayer.getPosition()
    }
    
    func getPlayerState() -> String {
        // Check push stream first (for gapless/direct streams)
        if streamDecoder.isPlaying() {
            return "Playing"
        }
        // Fall back to URL stream player state
        return audioPlayer.getPlayerState()
    }

    func hasPushStream() -> Bool {
        return streamDecoder.hasValidStream()  // Check for valid stream (playing OR paused)
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
        streamDecoder.setVolume(volume)  // Also apply to push streams
    }

    func getVolume() -> Float {
        // Return push stream volume if active, otherwise URL stream
        if streamDecoder.hasValidStream() {
            return streamDecoder.getVolume()
        }
        return audioPlayer.getVolume()
    }

    // MARK: - Silent Recovery Support
    /// Enable silent mode for the next stream (for app foreground recovery)
    func enableSilentRecoveryMode() {
        audioPlayer.muteNextStream = true
        streamDecoder.muteNextStream = true  // Also apply to push streams for gapless

        // CRITICAL FIX: If there's an existing push stream, flush and mute it IMMEDIATELY
        // This clears old buffered audio and ensures silence during recovery
        if streamDecoder.hasValidStream() {
            os_log(.error, log: logger, "[APP-RECOVERY] 🧹 FLUSHING EXISTING PUSH STREAM BUFFER")
            streamDecoder.flushBuffer()
            os_log(.error, log: logger, "[APP-RECOVERY] 🔇 MUTING FLUSHED STREAM")
            streamDecoder.applyMuting()
        }

        os_log(.error, log: logger, "[APP-RECOVERY] 🔇 SILENT RECOVERY MODE ENABLED")
        os_log(.error, log: logger, "[APP-RECOVERY] 📊 audioPlayer.muteNextStream = %{public}s", audioPlayer.muteNextStream ? "TRUE" : "FALSE")
        os_log(.error, log: logger, "[APP-RECOVERY] 📊 streamDecoder.muteNextStream = %{public}s", streamDecoder.muteNextStream ? "TRUE" : "FALSE")
        os_log(.error, log: logger, "[APP-RECOVERY] 📊 streamDecoder.hasValidStream() = %{public}s", streamDecoder.hasValidStream() ? "TRUE" : "FALSE")
    }

    /// Disable silent mode and restore normal DSP gain
    func disableSilentRecoveryMode() {
        audioPlayer.muteNextStream = false
        streamDecoder.muteNextStream = false
        audioPlayer.restoreDSPGain()
        streamDecoder.restoreDSPGain()
        os_log(.info, log: logger, "🔊 Silent recovery mode disabled - DSP gain restored")
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

    // Update playlist position for CarPlay button states
    func updatePlaylistPosition(currentIndex: Int, totalTracks: Int) {
        nowPlayingManager.updatePlaylistPosition(currentIndex: currentIndex, totalTracks: totalTracks)
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
        #if DEBUG
        os_log(.info, log: logger, "Refactored AudioManager deinitialized")
        #endif
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
        // Like squeezelite output.c:155 - output.track_started = true → send STMs
        // This updates Material UI to show the new track that's NOW PLAYING
        slimClient?.sendTrackStarted()
    }

    func audioStreamDecoderDidCompleteTrack(_ decoder: AudioStreamDecoder) {
        os_log(.info, log: logger, "✅ Track decode complete (natural end) - sending STMd to server")
        // Like squeezelite: DECODE_COMPLETE → wake_controller() → send STMd
        slimClient?.sendTrackDecodeComplete()
    }

    func audioStreamDecoderDidEncounterError(_ decoder: AudioStreamDecoder, error: Int) {
        os_log(.error, log: logger, "❌ Decoder error: %d - sending STMn to server", error)
        // Like squeezelite: DECODE_ERROR → send STMn
        slimClient?.sendTrackDecodeError()
    }

    func audioStreamDecoderDidStartDeferredTrack(_ decoder: AudioStreamDecoder) {
        os_log(.info, log: logger, "🎯 Deferred track started (format mismatch) - sending STMs!")
        // When deferred track starts after format mismatch, notify server
        // This updates Material UI to show the new track that's NOW PLAYING
        slimClient?.sendTrackStarted()
    }

    func audioStreamDecoderBufferReady(_ decoder: AudioStreamDecoder) {
        os_log(.info, log: logger, "📊 Buffer ready threshold reached - sending STMl!")
        // Notify server that buffer is loaded and ready for synchronized start
        // This allows server to transition from WAITING_TO_SYNC to PLAYING
        slimClient?.sendBufferLoaded()
    }
}
