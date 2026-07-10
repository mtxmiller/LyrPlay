// File: AudioManager.swift (Refactored)
// Coordinator that manages all audio components while preserving the exact same public interface
import Foundation
import AVFoundation
import Combine
import os.log

class AudioManager: NSObject, ObservableObject {

    static let shared = AudioManager()  // ← ADD THIS LINE

    // MARK: - Components
    let audioPlayer: AudioPlayer  // Made public for SettingsView access
    #if os(iOS)
    private let audioSessionManager: AudioSessionManager
    #endif
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

    /// Returns the currently-active BASS stream handle for FFT sampling, or 0 if none.
    /// Push stream (gapless playback path) is preferred since it's the active source on tvOS;
    /// falls back to the URL-stream handle for legacy direct-stream playback.
    func currentFFTStream() -> HSTREAM {
        let pushHandle = streamDecoder.activePushStream
        if pushHandle != 0 { return pushHandle }
        return audioPlayer.activeBASSStream
    }

    // MARK: - Rate Matching (forwarders for SyncController)
    func setRateOffsetPct(_ offsetPct: Double) {
        streamDecoder.setRateOffsetPct(offsetPct)
    }

    func setRateOffsetPctImmediate(_ offsetPct: Double) {
        streamDecoder.setRateOffsetPctImmediate(offsetPct)
    }

    func pushStreamPositionBytes() -> UInt64 {
        streamDecoder.pushStreamPositionBytes()
    }

    var nominalBytesPerSecond: Int { streamDecoder.nominalBytesPerSecond }

    // MARK: - Stream Info

    /// Applies an LMS-reported bitrate string to the stream-info display.
    /// Called from the JSON-RPC metadata path. Used as initial display +
    /// fallback for when the wire measurement isn't available (e.g. some
    /// remote streams). Measured bitrate (from `sampleAndApplyMeasuredBitrate`)
    /// takes precedence when available — LMS reports the *source* file's
    /// bitrate which is wrong for transcoded streams.
    func updateStreamBitrate(text: String?) {
        audioPlayer.applyServerBitrate(text)
    }

    /// Samples the actual wire bitrate from AudioStreamDecoder and applies it
    /// to the AudioPlayer's stream-info display. Called by SlimProtoCoordinator's
    /// 1Hz heartbeat. Codec-agnostic — works for any format LMS may transcode
    /// to. Returns the value applied (nil if measurement isn't yet stable).
    @discardableResult
    func sampleAndApplyMeasuredBitrate() -> String? {
        let measured = streamDecoder.sampleMeasuredBitrate()
        audioPlayer.applyMeasuredBitrate(measured)
        return measured
    }

    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioManager")
    
    // MARK: - Public Interface (Preserved from Original)
    var onTrackEnded: (() -> Void)?
    var slimClient: SlimProtoCoordinator?  // Changed from weak to strong reference
    
    // MARK: - Initialization
    private override init() {
        self.audioPlayer = AudioPlayer()
        #if os(iOS)
        self.audioSessionManager = AudioSessionManager()
        #endif
        self.nowPlayingManager = NowPlayingManager()
        self.streamDecoder = AudioStreamDecoder()  // NEW: Initialize decoder

        super.init()

        setupDelegation()

        // CRITICAL: Ensure NowPlayingManager gets AudioManager reference for fallback timing
        nowPlayingManager.setAudioManager(self)

        #if os(iOS)
        PlaybackSessionController.shared.configure(audioManager: self) { [weak self] in
            self?.slimClient
        }
        #else
        // tvOS: BASS_CONFIG_IOS_SESSION is iOS-only per BASS docs, so BASS does NOT
        // auto-manage AVAudioSession on tvOS. Activate after BASS_Init has run (in
        // AudioPlayer init above) so BASS sees a known-good init state, then mark
        // the app as a Now Playing candidate (gates HW remote events + lets
        // UIBackgroundModes audio keep playback alive on home screen).
        // Lazy callers in sendLockScreenCommand re-call this for transient-failure retry.
        activateAudioSession()
        #endif

        #if DEBUG
        os_log(.info, log: logger, "✅ AudioManager initialized with lock screen controls ready")
        #endif
    }
    
    // MARK: - Component Integration
    private func setupDelegation() {
        // Connect AudioPlayer to AudioManager
        audioPlayer.delegate = self
        audioPlayer.audioManager = self  // Set back-reference for media control refresh

        #if os(iOS)
        // Connect AudioSessionManager to AudioManager - ENHANCED
        audioSessionManager.delegate = self
        #endif

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
    func startPushStreamPlayback(url: String, format: String, replayGain: Float = 0.0, isGapless: Bool = false, startTime: Double = 0.0, waitForUnpause: Bool = false) {
        os_log(.info, log: logger, "📊 Starting push stream playback: %{public}s (gapless: %d, waitForSync: %{public}s)", format, isGapless, waitForUnpause ? "YES" : "NO")
        os_log(.debug, log: logger, "📊 Decoder URL: %{public}s", url)

        // Configure audio session
        configureAudioSessionForFormat(format)
        activateAudioSession()

        // Check if we need to initialize push stream (first time or after cleanup)
        let hasValidStream = streamDecoder.hasValidStream()

        if !hasValidStream {
            // First track (or post-cleanup): DON'T create the push stream here.
            // The decoder creates it at the stream's ACTUAL rate/channels once
            // BASS reports them (performStartDecoding) — the old flow created a
            // hardcoded 44.1k/2ch stream and immediately freed + recreated it
            // on mismatch, with an extra AVAudioSession preferred-rate change,
            // at the most latency-sensitive moment. ReplayGain is stored by the
            // decoder (setReplayGain guards on stream existence) and applied at
            // creation; startPlayback honors the sync-wait flag set below.
            // bd LMS_StreamTest-433.5.3
            os_log(.info, log: logger, "📊 First track - push stream will be created at decoder-reported format")

            if waitForUnpause {
                streamDecoder.markUnpausePending()
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

            // Sync-wait must be set AFTER stopDecoding() because stopDecoding clears
            // isWaitingForUnpause (it treats waiting state as cancellable on manual
            // stop). For track-change-during-sync we need the flag intact so flushBuffer
            // and any subsequent startPlayback honor it.
            if waitForUnpause {
                streamDecoder.markUnpausePending()
            }

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

        // Cancel any in-flight sync-correction resume — user/server play overrides it.
        cancelPendingResumeAll()

        // Control push stream or audio player depending on active mode
        if streamDecoder.hasValidStream() {
            streamDecoder.resumePlayback()
            os_log(.info, log: logger, "▶️ Resuming push stream playback")
        } else {
            audioPlayer.play()
        }
    }

    func pause() {
        // Cancel any in-flight sync-correction resume — explicit pause overrides it.
        cancelPendingResumeAll()

        // Control push stream or audio player depending on active mode
        if streamDecoder.hasValidStream() {
            streamDecoder.pausePlayback()
            os_log(.info, log: logger, "⏸️ Pausing push stream playback")
        } else {
            audioPlayer.pause()
        }
    }

    func stop() {
        // Cancel any in-flight sync-correction resume — stream is going away.
        cancelPendingResumeAll()

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

        // Cancel any in-flight sync-correction resume — synchronized start overrides it.
        cancelPendingResumeAll()

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

        // Defensive: if a pauseForInterval is in flight, cancel its pending resume
        // before the skipAhead lands. Server is unlikely to send 'a' during 'p' window
        // but cancellation is cheap and prevents a stale resume after the new state.
        cancelPendingResumeAll()

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

    /// Cancel any pending sync-correction resume on both AudioPlayer (URL stream)
    /// and AudioStreamDecoder (push stream). Called by stop/flush/skipAhead/unpause
    /// paths so a stale BASS_ChannelStart doesn't fire after the stream has changed
    /// state. See Fix 2 in sync drift plan.
    func cancelPendingResumeAll() {
        audioPlayer.cancelPendingResume()
        streamDecoder.cancelPendingResume()
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
    /// Uses hasValidStream() (PLAYING or PAUSED) so position is reported correctly during
    /// sync-correction pauses (Fix 2 BASS_ChannelPause window) — isPlaying() alone returned
    /// false for BASS_ACTIVE_PAUSED and fell through to audioPlayer.getCurrentTime() = 0,
    /// corrupting STAT elapsed_ms during the pause.
    internal func getAudioPlayerTimeForFallback() -> Double {
        if streamDecoder.hasValidStream() {
            return streamDecoder.getCurrentPosition()
        }
        return audioPlayer.getCurrentTime()
    }

    /// Real STAT buffer/byte telemetry from whichever stream path is active.
    func statTelemetry() -> SlimProtoStatTelemetry {
        if streamDecoder.hasValidStream() {
            return streamDecoder.statTelemetry()
        }
        return audioPlayer.statTelemetry()
    }
    
    func getDuration() -> Double {
        return audioPlayer.getDuration()
    }
    
    func getPosition() -> Float {
        // Use decoder position for push streams, audio player position for URL streams.
        // hasValidStream() (not isPlaying()) so a PAUSED push stream reports its real
        // position instead of falling through to the idle URL player's 0 — same fix
        // getAudioPlayerTimeForFallback already has.
        if streamDecoder.hasValidStream() {
            return Float(streamDecoder.getCurrentPosition())
        }
        return audioPlayer.getPosition()
    }

    func getPlayerState() -> String {
        // Check push stream first (for gapless/direct streams). hasValidStream()
        // (not isPlaying()) so a PAUSED push stream reports "Paused" instead of
        // falling through to the idle URL player's "Stopped".
        if streamDecoder.hasValidStream() {
            return streamDecoder.getPlayerState()
        }
        // Fall back to URL stream player state
        return audioPlayer.getPlayerState()
    }

    func hasPushStream() -> Bool {
        return streamDecoder.hasValidStream()  // Check for valid stream (playing OR paused)
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

        // Also mute any existing legacy URL stream (FLAC/seek path) immediately. Setting
        // muteNextStream only covers the NEXT stream, so a currently-playing legacy stream
        // would otherwise stay audible during the recovery window.
        audioPlayer.applyMuting()

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

    #if os(iOS)
    func activateAudioSession(context: PlaybackSessionController.ActivationContext = .userInitiatedPlay) {
        // BASS automatically manages iOS audio session - no manual activation needed
        os_log(.info, log: logger, "🔒 Audio session activation (BASS auto-managed - no action needed)")
    }
    #else
    func activateAudioSession() {
        // Idempotent: setCategory/setActive on already-active session is a no-op.
        // Eager activation runs in init(); this exists for lazy callers
        // (sendLockScreenCommand etc.) that act as retry on transient failure.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true, options: [])
        } catch {
            os_log(.error, log: logger, "❌ tvOS AVAudioSession (re)activation failed: %{public}s", error.localizedDescription)
        }
    }
    #endif

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

        #if os(iOS)
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
        #endif
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
    
    func audioPlayerDidReceiveMetadata(_ metadata: (title: String?, artist: String?)) {
        // Forward ICY metadata to SlimProto coordinator (logging handled there)
        slimClient?.handleICYMetadata(metadata)
    }
}

#if os(iOS)
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
        os_log(.info, log: logger, "🚫 Audio interrupted (PlaybackSessionController handles server commands)")
    }

    func audioSessionInterruptionEnded(shouldResume: Bool) {
        os_log(.info, log: logger, "✅ Interruption ended (PlaybackSessionController handles server commands)")
    }

    func audioSessionRouteChanged(shouldPause: Bool) {
        let routeChangeDescription = audioSessionManager.interruptionManager?.lastRouteChange?.description ?? "Unknown"
        os_log(.info, log: logger, "🔀 Route change: %{public}s (PlaybackSessionController handles server commands)", routeChangeDescription)
    }
}

// MARK: - Debug and Utility Methods
extension AudioManager {

    func getCurrentAudioRoute() -> String {
        return audioSessionManager.getCurrentAudioRoute()
    }

    func isOtherAudioPlaying() -> Bool {
        return audioSessionManager.isOtherAudioPlaying()
    }
}
#endif

// MARK: - Server Time Integration (cross-platform)
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

    func audioStreamDecoderDidDrainAfterTrackComplete(_ decoder: AudioStreamDecoder) {
        os_log(.info, log: logger, "🏁 Output drained after decode complete - sending STMu to server")
        // Like squeezelite: output empty + DECODE_STOPPED + stream disconnected → STMu.
        // At end-of-playlist the server answers with a clean stop (strm 'q');
        // mid-playlist (slow next track) it plays the queued song when ready.
        slimClient?.sendPlaybackComplete()
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

    func audioStreamDecoderDidRecreatePushStream(_ decoder: AudioStreamDecoder) {
        slimClient?.syncControllerReset(reason: "pushStreamRecreated")
    }

    func audioStreamDecoderDidStartPlayback(_ decoder: AudioStreamDecoder) {
        // Forward to coordinator so STMs can be flushed at the precise moment
        // audio production starts. Mirrors squeezelite's output.track_started.
        slimClient?.handleDecoderDidStartPlayback()
    }
}
