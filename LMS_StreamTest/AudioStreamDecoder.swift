// File: AudioStreamDecoder.swift
// Buffer-level gapless playback implementation using BASS push streams
// Based on squeezelite's proven architecture
import Foundation
import os.log

// MARK: - Global BASS Callbacks

/// Global callback for track boundary sync
private func bassTrackBoundaryCallback(handle: HSYNC, channel: DWORD, data: DWORD, user: UnsafeMutableRawPointer?) {
    guard let user = user else { return }
    let decoder = Unmanaged<AudioStreamDecoder>.fromOpaque(user).takeUnretainedValue()

    DispatchQueue.main.async {
        decoder.handleTrackBoundary()
    }
}

/// Global callback for buffer end/stall (when all audio has been played)
/// For push streams, BASS_SYNC_STALL with data=0 indicates buffer empty
private func bassBufferEndCallback(handle: HSYNC, channel: DWORD, data: DWORD, user: UnsafeMutableRawPointer?) {
    guard let user = user else { return }
    let decoder = Unmanaged<AudioStreamDecoder>.fromOpaque(user).takeUnretainedValue()

    // data=0 means stalled (buffer empty), data=1 means resumed
    if data == 0 {
        os_log(.error, "⚠️ BUFFER STALLED - playback interrupted!")
        DispatchQueue.main.async {
            decoder.handleBufferEnd()
        }
    } else {
        os_log(.info, "✅ Buffer resumed after stall")
    }
}

/// Manages BASS push stream for gapless playback
/// Decodes audio chunks from SlimProto and feeds them to a single continuous BASS buffer
class AudioStreamDecoder {

    // MARK: - Properties

    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioStreamDecoder")

    /// BASS push stream handle (single instance for gapless)
    private var pushStream: HSTREAM = 0

    /// BASS decoder stream handle (decodes HTTP URL without playing)
    private var decoderStream: HSTREAM = 0

    /// Current audio format being decoded
    private var currentFormat: String?

    /// Sample rate of current stream
    private var sampleRate: Int = 44100

    /// Number of channels (1=mono, 2=stereo)
    private var channels: Int = 2

    /// Decoding queue for async processing
    private let decodeQueue: DispatchQueue

    /// Flag indicating if decoder is actively processing
    private var isDecoding: Bool = false

    /// Flag to track if decoder was manually stopped (vs natural completion)
    private var manualStop: Bool = false

    /// Track total bytes decoded and pushed (for debugging)
    private var totalBytesPushed: UInt64 = 0

    /// Track bytes at last buffer diagnostic log (for throttling)
    private var lastBufferDiagnosticBytes: UInt64 = 0

    /// Track boundary position in buffer (for gapless transitions)
    private var trackBoundaryPosition: UInt64?

    /// Flag to mark boundary on next decoded chunk (like squeezelite's decode.new_stream)
    /// Set when new STRM arrives, cleared when first chunk of new track is written
    /// This ensures boundary is marked AFTER old decoder finishes pushing buffered audio
    private var pendingTrackBoundary: Bool = false

    /// Track start time offset (seconds into track where this stream starts)
    /// Used for server-side seeks where stream starts at non-zero track position
    private var trackStartTimeOffset: Double = 0.0

    /// Metadata for next track (applied at boundary)
    private var nextTrackMetadata: TrackMetadata?

    /// Last time we logged "buffer empty" message (for rate limiting)
    private var lastBufferEmptyLogTime: Date = .distantPast

    /// Last time we logged "before boundary" position (for rate limiting to prevent duplicate logs)
    private var lastBeforeBoundaryLogTime: Date = .distantPast

    /// Current track start position (for accurate position tracking)
    private var trackStartPosition: UInt64 = 0

    /// Previous track start position (for reporting position before boundary crossed)
    /// When queueing gapless track, trackStartPosition gets updated to boundary
    /// But we need to keep reporting old track's position until boundary is reached
    private var previousTrackStartPosition: UInt64 = 0

    /// Pending track info for deferred start (when format mismatch during gapless transition)
    /// When next track has different sample rate/channels, we defer starting it until current track finishes
    private var pendingTrack: PendingTrackInfo? = nil

    /// Information about a track that's waiting to start (due to format mismatch)
    /// Stores decoder handle to keep HTTP connection alive and preserve position 0:00
    private struct PendingTrackInfo {
        let url: String
        let format: String
        let decoderStream: HSTREAM  // Keep HTTP connection alive!
        let sampleRate: Int
        let channels: Int
    }

    /// Maximum buffer size before throttling (in bytes)
    /// Default: ~4 seconds @ 44.1kHz stereo float = 44100 * 2 * 4 * 4 = 705,600 bytes
    private let maxBufferSize: Int = 705_600

    // MARK: - Silent Recovery Support
    /// Flag to mute the next stream creation (for silent app foreground recovery)
    /// When true, DSP gain is set to 0.001 immediately upon push stream playback start
    var muteNextStream: Bool = false

    // MARK: - Volume and ReplayGain Support
    /// Current volume level (0.0 to 1.0) - applied via BASS_ATTRIB_VOL
    private var currentVolume: Float = 1.0

    /// Current replay gain (linear multiplier) - applied via BASS_ATTRIB_VOLDSP
    /// Server sends as 16.16 fixed point, converted to float (e.g., 0.501 for -6dB)
    private var currentReplayGain: Float = 1.0

    /// Registered sync handles (for cleanup)
    private var trackBoundarySyncs: [HSYNC] = []

    /// CRITICAL: Separate storage for STALL sync (buffer end detection)
    /// This sync must persist across track boundaries to detect when buffer empties
    /// for deferred track starts (format mismatch scenarios)
    private var stallSync: HSYNC = 0

    /// Throttle log counter to avoid spam (throttle can happen 10x/sec)
    private var throttleLogCounter: Int = 0

    // MARK: - Synchronized Start for Multi-Room Audio

    /// Target jiffies time for synchronized start (nil = start immediately)
    private var syncStartJiffies: TimeInterval?

    /// Monitoring timer for delayed start
    private var syncStartMonitorTimer: Timer?

    /// Flag to track if we're buffering for synchronized start
    private var isWaitingForSyncStart: Bool = false

    // MARK: - Buffer Skip Ahead for Multi-Room Audio

    /// Number of bytes remaining to skip (for drift correction when player is behind)
    /// Decoder loop checks this and discards data instead of pushing to BASS
    private var skipAheadBytesRemaining: Int = 0

    // MARK: - Buffer Ready Signaling for Multi-Room Audio

    /// Flag to track if we've sent STMl (buffer loaded) for current track
    /// Reset when starting new track, set when buffer threshold reached
    private var sentSTMl: Bool = false

    /// Buffer threshold for STMl signaling (2 seconds of audio)
    /// When buffer reaches this level, we signal server we're ready for sync
    private var bufferReadyThreshold: Int {
        return sampleRate * channels * 4 * 2  // 2 seconds
    }

    /// Start playback at a specific jiffies time for synchronized multi-room audio
    /// - Parameter targetJiffies: Target jiffies time (ProcessInfo.systemUptime when to start)
    ///
    /// This delays BASS_ChannelPlay() until the target time while continuing to buffer audio
    /// data via BASS_StreamPutData(). This allows multiple players to start in sync.
    func startAtJiffies(_ targetJiffies: TimeInterval) {
        os_log(.info, log: logger, "🎯 Scheduling synchronized start at jiffies: %.3f", targetJiffies)

        // Store target jiffies and set waiting flag
        syncStartJiffies = targetJiffies
        isWaitingForSyncStart = true

        // Start monitoring timer (check every 100ms like AudioPlayer)
        startSyncStartMonitoring(targetJiffies: targetJiffies)
    }

    /// Start monitoring timer for synchronized start
    private func startSyncStartMonitoring(targetJiffies: TimeInterval) {
        // Clean up any existing timer first
        stopSyncStartMonitoring()

        os_log(.info, log: logger, "🎯 Starting sync start monitoring timer")

        // CRITICAL: Timer must be scheduled on main thread - socket callbacks are on background thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.syncStartMonitorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let currentJiffies = ProcessInfo.processInfo.systemUptime

            // Check if we've reached the target time
            if currentJiffies >= targetJiffies {
                os_log(.info, log: self.logger, "🎯 Target jiffies reached! Current: %.3f >= Target: %.3f", currentJiffies, targetJiffies)
                os_log(.info, log: self.logger, "▶️ Starting synchronized playback NOW")

                // Clear waiting flag and start playback
                self.isWaitingForSyncStart = false
                self.syncStartJiffies = nil
                self.stopSyncStartMonitoring()

                // Now actually start BASS playback
                guard self.pushStream != 0 else {
                    os_log(.error, log: self.logger, "❌ Cannot start - no push stream")
                    return
                }

                let result = BASS_ChannelPlay(self.pushStream, 0)

                if result != 0 {
                    // Apply muting if needed (for silent recovery)
                    if self.muteNextStream {
                        BASS_ChannelSetAttribute(self.pushStream, DWORD(BASS_ATTRIB_VOLDSP), 0.001)
                        os_log(.info, log: self.logger, "🔇 DSP gain = 0.001 (synchronized start with muting)")
                    }

                    os_log(.info, log: self.logger, "✅ Synchronized playback started successfully (muted: %{public}s)", self.muteNextStream ? "YES" : "NO")
                } else {
                    let error = BASS_ErrorGetCode()
                    os_log(.error, log: self.logger, "❌ Synchronized play failed: %d", error)
                }
            }
        }
        } // end DispatchQueue.main.async
    }

    /// Stop sync start monitoring timer
    private func stopSyncStartMonitoring() {
        syncStartMonitorTimer?.invalidate()
        syncStartMonitorTimer = nil
    }

    // MARK: - Silence Injection for Multi-Room Audio

    /// Play silence for a specified duration (drift correction when player is ahead)
    /// - Parameter duration: Duration of silence in seconds
    ///
    /// This injects zero bytes into the push stream to slow down playback and maintain sync.
    /// Used when this player is ahead of the sync group and needs to pause momentarily.
    func playSilence(duration: TimeInterval) {
        guard pushStream != 0 else {
            os_log(.error, log: logger, "❌ Cannot play silence - no push stream")
            return
        }

        guard duration > 0 else {
            os_log(.info, log: logger, "🔇 Zero duration silence - skipping")
            return
        }

        os_log(.info, log: logger, "🔇 Playing %.3f seconds of silence for drift correction", duration)

        // Calculate how many bytes of silence to generate
        // Float samples = 4 bytes per sample
        let bytesPerSecond = sampleRate * channels * 4
        let silenceBytes = Int(duration * Double(bytesPerSecond))

        // Create buffer of zeros (silence in float PCM is 0.0)
        let silenceBuffer = [Float](repeating: 0.0, count: silenceBytes / 4)

        // Push silence to stream
        let pushed = silenceBuffer.withUnsafeBytes { ptr in
            BASS_StreamPutData(
                pushStream,
                UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                UInt32(silenceBytes)
            )
        }

        if pushed == DWORD.max {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Failed to inject silence: BASS error %d", error)
        } else {
            // Track the silence in our total bytes pushed
            totalBytesPushed += UInt64(silenceBytes)

            let queuedAmount = Int(pushed)
            os_log(.info, log: logger, "✅ Injected %d bytes (%.3f seconds) of silence, queue now: %d KB",
                   silenceBytes, duration, queuedAmount / 1024)
        }
    }

    // MARK: - Buffer Skip Ahead for Multi-Room Audio

    /// Skip ahead by discarding decoded audio for a specified duration (drift correction when player is behind)
    /// - Parameter duration: Duration to skip in seconds
    ///
    /// This reads from the decoder but doesn't push to BASS, effectively skipping ahead.
    /// Used when this player is behind the sync group and needs to catch up.
    func skipAhead(duration: TimeInterval) {
        guard pushStream != 0 else {
            os_log(.error, log: logger, "❌ Cannot skip ahead - no push stream")
            return
        }

        guard duration > 0 else {
            os_log(.info, log: logger, "⏩ Zero duration skip - ignoring")
            return
        }

        os_log(.info, log: logger, "⏩ Skipping ahead %.3f seconds for drift correction", duration)

        // Calculate how many bytes to skip
        // Float samples = 4 bytes per sample
        let bytesPerSecond = sampleRate * channels * 4
        let bytesToSkip = Int(duration * Double(bytesPerSecond))

        // Set the skip counter - decoder loop will discard this many bytes
        // Access is thread-safe because decoder loop runs on decodeQueue exclusively
        skipAheadBytesRemaining = bytesToSkip

        os_log(.info, log: logger, "⏩ Will discard next %d bytes (%.3f seconds) from decoder",
               bytesToSkip, duration)
    }

    // MARK: - Delegate

    weak var delegate: AudioStreamDecoderDelegate?
    weak var audioPlayer: AudioPlayer?  // Reference to update stream info

    // MARK: - Initialization

    init() {
        decodeQueue = DispatchQueue(label: "com.lyrplay.decoder", qos: .userInitiated)
        #if DEBUG
        os_log(.info, log: logger, "✅ AudioStreamDecoder initialized")
        #endif
    }

    // MARK: - Push Stream Management

    /// Initialize BASS push stream (called once per playback session)
    func initializePushStream(sampleRate: Int = 44100, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = channels

        os_log(.info, log: logger, "🎵 Creating push stream: %d Hz, %d channels", sampleRate, channels)

        // Create push stream with STREAMPROC_PUSH
        // STREAMPROC_PUSH is defined as (STREAMPROC*)-1 in bass.h
        // Use helper function from bridging header to get the sentinel value
        pushStream = BASS_StreamCreate(
            UInt32(sampleRate),
            UInt32(channels),
            DWORD(BASS_SAMPLE_FLOAT),  // 32-bit float samples like squeezelite
            getLyrPlayStreamProcPush(),  // STREAMPROC_PUSH = -1
            nil
        )

        guard pushStream != 0 else {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Push stream creation failed: %d", error)
            return
        }

        // CRITICAL: Set hard limit on queue buffer to prevent runaway memory usage
        // This prevents decoding entire podcasts (60min = 1.2GB!) into RAM
        // 600 MB = room for large FLAC files (500MB+) and gapless playback queue
        let hardLimitBytes: Float = 600_000_000  // 600 MB
        BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_PUSH_LIMIT), hardLimitBytes)
        os_log(.info, log: logger, "🔒 Set push stream queue limit: %.0f MB", hardLimitBytes / 1_048_576)

        // Set up buffer stall detection
        setupSyncCallbacks()

        // Apply stored volume setting (server may have sent audg before stream existed)
        if currentVolume != 1.0 {
            BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOL), currentVolume)
            os_log(.info, log: logger, "🔊 Applied stored volume to new stream: %.2f", currentVolume)
        }

        os_log(.info, log: logger, "✅ Push stream created: handle=%d", pushStream)
    }

    /// Set up BASS sync callbacks for monitoring
    private func setupSyncCallbacks() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Buffer stall monitoring - also detects buffer end for push streams
        // For push streams, STALL with data=0 means buffer empty (track finished)
        // This is how we detect when to start deferred tracks
        // CRITICAL: Store separately from trackBoundarySyncs so it persists across track boundaries
        stallSync = BASS_ChannelSetSync(
            pushStream,
            DWORD(BASS_SYNC_STALL),
            0,
            bassBufferEndCallback,  // Use buffer end callback to handle deferred tracks
            selfPtr
        )

        os_log(.info, log: logger, "✅ Sync callbacks registered (STALL sync: %d)", stallSync)
    }

    /// Start BASS playback of push stream
    func startPlayback() -> Bool {
        guard pushStream != 0 else {
            os_log(.error, log: logger, "❌ Cannot start playback - no push stream")
            return false
        }

        // If waiting for synchronized start, don't play immediately
        // Decoder loop will continue buffering data via BASS_StreamPutData
        // Timer will call BASS_ChannelPlay when target jiffies is reached
        if isWaitingForSyncStart {
            os_log(.debug, log: logger, "🎯 Buffering for synchronized start (target: %.3f) - NOT starting playback yet", syncStartJiffies ?? 0)
            os_log(.debug, log: logger, "📊 Decoder will continue pushing data, playback will start at target time")
            return true  // Return success - we're ready, just waiting for sync time
        }

        let result = BASS_ChannelPlay(pushStream, 0)

        if result != 0 {
            // SILENT RECOVERY: Mute using DSP gain (like ReplayGain) instead of volume
            // BASS_ATTRIB_VOLDSP applies gain to sample data - should actually work!
            // Use 0.001 instead of 0.0 to avoid any potential edge cases (-60dB = effectively silent)
            if muteNextStream {
                BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOLDSP), 0.001)
                os_log(.info, log: logger, "🔇 APP OPEN RECOVERY: DSP gain = 0.001 (sample-level muting, -60dB)")
            }

            os_log(.info, log: logger, "▶️ Push stream playback started (muted: %{public}s)", muteNextStream ? "YES" : "NO")
            return true
        } else {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Push stream play failed: %d", error)
            return false
        }
    }

    /// Pause push stream playback
    func pausePlayback() {
        guard pushStream != 0 else { return }
        BASS_ChannelPause(pushStream)
        os_log(.info, log: logger, "⏸️ Push stream paused")
    }

    /// Resume push stream playback
    func resumePlayback() {
        guard pushStream != 0 else {
            os_log(.error, log: logger, "[APP-RECOVERY] ❌ Cannot resume - no push stream")
            return
        }

        os_log(.error, log: logger, "[APP-RECOVERY] ▶️ RESUMING PUSH STREAM PLAYBACK")

        // SILENT RECOVERY: Apply muting if requested (for app foreground recovery)
        // resumePlayback() bypasses startPlayback(), so we need to check muteNextStream here too
        if muteNextStream {
            BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOLDSP), 0.001)
            os_log(.error, log: logger, "[APP-RECOVERY] 🔇 APPLYING MUTING: DSP gain = 0.001 (resumed stream muting)")
        } else {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔊 NO MUTING: muteNextStream = FALSE")
        }

        let result = BASS_ChannelPlay(pushStream, 0)
        if result != 0 {
            os_log(.error, log: logger, "[APP-RECOVERY] ✅ Push stream resumed successfully (muted: %{public}s)", muteNextStream ? "YES" : "NO")
        } else {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "[APP-RECOVERY] ❌ Push stream resume failed: BASS error %d", error)
        }
    }

    /// Apply muting (DSP gain) to current push stream
    /// Used when flushBuffer() bypasses startPlayback()
    func applyMuting() {
        guard pushStream != 0 else { return }

        BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOLDSP), 0.001)
        os_log(.info, log: logger, "🔇 APP OPEN RECOVERY: DSP gain = 0.001 (manual muting)")
    }

    /// Restore DSP gain to 1.0 after silent recovery
    func restoreDSPGain() {
        guard pushStream != 0 else { return }

        BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOLDSP), 1.0)
        os_log(.info, log: logger, "🔊 APP OPEN RECOVERY: DSP gain restored to 1.0")
    }

    // MARK: - Volume Control (Server UI Volume)

    /// Set volume level from server audg command
    /// This controls the playback volume (BASS_ATTRIB_VOL)
    func setVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        currentVolume = clampedVolume

        guard pushStream != 0 else {
            #if DEBUG
            os_log(.debug, log: logger, "🔊 Volume stored (no stream): %.2f", clampedVolume)
            #endif
            return
        }

        BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOL), clampedVolume)
        #if DEBUG
        os_log(.debug, log: logger, "🔊 Volume set: %.2f", clampedVolume)
        #endif
    }

    /// Get current volume level
    func getVolume() -> Float {
        guard pushStream != 0 else { return currentVolume }

        var volume: Float = 1.0
        BASS_ChannelGetAttribute(pushStream, DWORD(BASS_ATTRIB_VOL), &volume)
        return volume
    }

    // MARK: - ReplayGain Support

    /// Apply replay gain from server STRM command
    /// Uses BASS_ATTRIB_VOLDSP for sample-level gain (like squeezelite)
    /// - Parameter gain: Linear gain multiplier (e.g., 0.501 for -6dB, 1.412 for +3dB)
    func setReplayGain(_ gain: Float) {
        // Clamp to prevent distortion (max 2x = +6dB boost)
        let clampedGain = min(max(gain, 0.0), 2.0)
        currentReplayGain = clampedGain

        guard pushStream != 0 else {
            os_log(.info, log: logger, "🎚️ ReplayGain stored (no stream): %.4f", clampedGain)
            return
        }

        // Don't apply if we're in silent recovery mode (muteNextStream)
        if muteNextStream {
            os_log(.info, log: logger, "🎚️ ReplayGain stored (muted for recovery): %.4f", clampedGain)
            return
        }

        BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOLDSP), clampedGain)
        os_log(.info, log: logger, "🎚️ ReplayGain applied: %.4f", clampedGain)
    }

    /// Get current replay gain value
    func getReplayGain() -> Float {
        return currentReplayGain
    }

    /// Apply stored volume and replay gain to current stream
    /// Called after stream creation or when restoring from muted state
    private func applyStoredGainSettings() {
        guard pushStream != 0 else { return }

        // Apply volume
        BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOL), currentVolume)

        // Apply replay gain (only if not in silent recovery mode)
        if !muteNextStream && currentReplayGain != 1.0 {
            BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOLDSP), currentReplayGain)
        }

        os_log(.info, log: logger, "🔊 Applied stored settings: volume=%.2f, replayGain=%.4f", currentVolume, currentReplayGain)
    }

    // MARK: - Decoder Stream Management

    /// Start decoding from HTTP URL (like squeezelite's decoder thread)
    /// - Parameters:
    ///   - url: HTTP URL to decode from
    ///   - format: Audio format (flc, mp3, ops, etc.)
    ///   - isNewTrack: Whether this is a new track (for gapless boundary marking)
    ///   - startTime: Seconds into track where this stream starts (for server-side seeks)
    ///   - replayGain: Linear gain multiplier from server (1.0 = no change)
    func startDecodingFromURL(_ url: String, format: String, isNewTrack: Bool = false, startTime: Double = 0.0, replayGain: Float = 1.0) {
        os_log(.info, log: logger, "🎵 Starting decoder for %{public}s: %{public}s (startTime: %.2f, replayGain: %.4f)", format, url, startTime, replayGain)

        // Reset STMl flag for new track
        sentSTMl = false
        os_log(.info, log: logger, "🎯 Reset sentSTMl flag for new track")

        // Apply replay gain for this track (stored and applied when not in silent recovery mode)
        if replayGain > 0.0 && replayGain != 1.0 {
            setReplayGain(replayGain)
        } else {
            // Reset to default (no gain adjustment)
            currentReplayGain = 1.0
        }

        // Store track start time offset for server-side seeks
        trackStartTimeOffset = startTime

        currentFormat = format

        // DON'T reset totalBytesPushed yet - we need it to mark the boundary first!

        // Create decode-only stream from URL (like squeezelite's streambuf)
        // BASS_STREAM_DECODE = no playback, just decode
        // BASS_SAMPLE_FLOAT = 32-bit float PCM output
        guard let urlCString = url.cString(using: .utf8) else {
            os_log(.error, log: logger, "❌ Invalid URL string")
            return
        }

        decoderStream = BASS_StreamCreateURL(
            urlCString,
            0,
            DWORD(BASS_STREAM_DECODE | BASS_SAMPLE_FLOAT),
            nil,
            nil
        )

        guard decoderStream != 0 else {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Decoder stream creation failed: %d", error)
            return
        }

        // CRITICAL: Get actual sample rate from decoder stream
        var info = BASS_CHANNELINFO()
        BASS_ChannelGetInfo(decoderStream, &info)
        let actualSampleRate = Int(info.freq)
        let actualChannels = Int(info.chans)

        os_log(.info, log: logger, "✅ Decoder created: %dHz, %dch (expected: %dHz, %dch)",
               actualSampleRate, actualChannels, sampleRate, channels)

        // Update stream info for SettingsView display (using decoder stream info)
        updateStreamInfoFromDecoder(decoderStream)

        // If sample rate doesn't match, we need to recreate push stream
        if actualSampleRate != sampleRate || actualChannels != channels {
            os_log(.error, log: logger, "⚠️ Format mismatch! Decoder: %dHz/%dch, Stream: %dHz/%dch",
                   actualSampleRate, actualChannels, sampleRate, channels)

            // CRITICAL: If this is a gapless transition, defer the track start!
            // We can't recreate the stream now because it would destroy buffered audio
            // Instead, store the pending track and wait for buffer to empty
            if isNewTrack {
                os_log(.error, log: logger, "🎵 Gapless transition with format mismatch - DEFERRING track start")
                os_log(.error, log: logger, "📊 Current track will play to completion, then new track will start")
                os_log(.error, log: logger, "📊 Keeping decoder alive to preserve HTTP connection from position 0:00")

                // Store pending track info WITH live decoder
                // CRITICAL: Don't close decoder! Keep HTTP connection open so we get track from 0:00
                pendingTrack = PendingTrackInfo(
                    url: url,
                    format: format,
                    decoderStream: decoderStream,  // Keep alive!
                    sampleRate: actualSampleRate,
                    channels: actualChannels
                )

                // DON'T close decoder - we need to keep the HTTP connection alive
                // If we close it, we lose the beginning of the track
                // Set to 0 so stopDecoding() doesn't try to free it
                decoderStream = 0

                // Return early - don't start decoder loop yet
                // Buffer end callback will start this track when current track finishes
                return
            }

            // Not gapless - safe to recreate stream immediately
            os_log(.error, log: logger, "⚠️ Format mismatch! Recreating push stream to match decoder")

            // Update our stored format
            sampleRate = actualSampleRate
            channels = actualChannels

            // Recreate push stream with correct format
            if pushStream != 0 {
                BASS_StreamFree(pushStream)
            }

            initializePushStream(sampleRate: sampleRate, channels: channels)
            startPlayback()
        }

        // Mark position tracking
        if pushStream != 0 {
            if isNewTrack {
                // New track: Set flag to mark boundary when FIRST DECODED CHUNK is written
                // Like squeezelite: decode.new_stream = true when STRM arrives
                // Boundary gets marked when first frame is actually written to buffer
                // This ensures old decoder finishes pushing buffered audio before boundary
                pendingTrackBoundary = true
                os_log(.info, log: logger, "🎯 New track pending - boundary will be marked when first decoded chunk is written")

                // CRITICAL: Save old track start BEFORE new boundary is marked
                // Need this to continue reporting old track's position until boundary crossed
                previousTrackStartPosition = trackStartPosition
                os_log(.info, log: logger, "📊 Saved previous track start: %llu", previousTrackStartPosition)

                // CRITICAL: Do NOT reset totalBytesPushed! It must be cumulative like squeezelite's writep!
                // totalBytesPushed tracks the absolute write position in the push stream buffer
                // BASS sync callbacks use absolute positions, so totalBytesPushed must remain cumulative
                os_log(.info, log: logger, "📊 Continuing cumulative write tracking: totalBytesPushed=%llu", totalBytesPushed)
            } else {
                // First track: Mark current playback position as track start
                let currentPlaybackPosition = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
                previousTrackStartPosition = 0  // No previous track
                trackStartPosition = currentPlaybackPosition
                os_log(.info, log: logger, "🎯 First track - marking start position: %llu", trackStartPosition)

                // For first track, totalBytesPushed should start at current playback position
                // This handles cases where push stream already has data
                totalBytesPushed = currentPlaybackPosition
                os_log(.info, log: logger, "📊 Initializing cumulative write tracking: totalBytesPushed=%llu", totalBytesPushed)
            }
        }

        // Start decoder loop (like squeezelite's decode_thread)
        isDecoding = true
        manualStop = false  // This is a fresh start, not a manual stop
        startDecoderLoop()
    }

    /// Stop current decoder stream
    func stopDecoding() {
        os_log(.info, log: logger, "⏹️ Stopping decoder (manual stop)")
        manualStop = true  // Mark as manual stop
        isDecoding = false

        // Clean up sync start monitoring
        if isWaitingForSyncStart {
            os_log(.debug, log: logger, "🎯 Canceling synchronized start due to manual stop")
            stopSyncStartMonitoring()
            isWaitingForSyncStart = false
            syncStartJiffies = nil
        }

        // Clear any pending track (user manually stopped, so don't start deferred track)
        if let pending = pendingTrack {
            os_log(.info, log: logger, "🎵 Clearing pending track due to manual stop")
            // Free the pending decoder stream (HTTP connection)
            if pending.decoderStream != 0 {
                BASS_StreamFree(pending.decoderStream)
                os_log(.info, log: logger, "🧹 Freed pending decoder stream")
            }
            pendingTrack = nil
        }

        if decoderStream != 0 {
            BASS_StreamFree(decoderStream)
            decoderStream = 0
        }
    }

    /// Flush push stream buffer (clear all buffered audio)
    /// Used when starting a new track to remove old audio
    /// Per BASS docs: "User streams... it is possible to reset a user stream
    /// (including its buffer contents) by setting its position to byte 0."
    func flushBuffer() {
        guard pushStream != 0 else { return }

        let buffered = BASS_ChannelGetData(pushStream, nil, DWORD(BASS_DATA_AVAILABLE))
        let currentPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
        os_log(.info, log: logger, "🧹 Flushing buffer: %d bytes buffered, position at %llu BEFORE flush", buffered, currentPos)

        // CRITICAL: DON'T stop stream - BASS auto-manages audio session/device changes
        // Stopping interferes with BASS's automatic route change handling
        // Just reset position and restart to clear buffer

        // Method 1: Set position to 0 to reset stream (per BASS docs)
        // This resets both buffer contents AND position counter
        BASS_ChannelSetPosition(pushStream, 0, DWORD(BASS_POS_BYTE))

        // Method 2: Restart to clear the buffer
        // BASS_ChannelPlay with restart=TRUE clears buffer contents
        // Trust BASS to handle device switching automatically
        let result = BASS_ChannelPlay(pushStream, 1)  // 1 = restart (clears buffer)
        if result != 0 {
            // Verify position was reset
            let newPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
            os_log(.info, log: logger, "📊 BASS position AFTER flush: %llu (should be 0)", newPos)

            trackStartPosition = 0  // Reset track start for position calculation
            previousTrackStartPosition = 0
            trackBoundaryPosition = nil  // Clear old gapless boundary from previous track
            totalBytesPushed = 0  // Reset write position
            lastBufferDiagnosticBytes = 0  // Reset buffer diagnostic counter
            os_log(.info, log: logger, "✅ Buffer flushed and restarted - BASS auto-handled device switching")
        } else {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Failed to flush buffer: error %d", error)
        }
    }

    /// Decoder loop - pulls PCM from decoder stream and pushes to push stream
    /// This matches squeezelite's decode_thread() architecture
    private func startDecoderLoop() {
        decodeQueue.async { [weak self] in
            guard let self = self else { return }

            os_log(.info, log: self.logger, "🔄 Decoder loop started")

            // Buffer for decoded PCM (4KB chunks like squeezelite)
            let bufferSize = 4096
            var buffer = [Float](repeating: 0, count: bufferSize)

            while self.isDecoding && self.decoderStream != 0 {
                // Check if push stream has space (like squeezelite checks outputbuf space)
                guard self.pushStream != 0 else {
                    os_log(.error, log: self.logger, "⚠️ No push stream available")
                    break
                }

                let buffered = BASS_ChannelGetData(self.pushStream, nil, DWORD(BASS_DATA_AVAILABLE))

                // Throttle if buffer is getting full (like squeezelite)
                if buffered > self.maxBufferSize {
                    Thread.sleep(forTimeInterval: 0.05)
                    continue
                }

                // Pull decoded PCM from decoder stream (like squeezelite's read_cb)
                let bytesRead = BASS_ChannelGetData(
                    self.decoderStream,
                    &buffer,
                    DWORD(bufferSize * 4)  // 4 bytes per float
                )

                // Check for error
                if bytesRead == DWORD.max {
                    let error = BASS_ErrorGetCode()

                    if error == DWORD(BASS_ERROR_ENDED) {
                        // BASS_ERROR_ENDED means decoder buffer is empty right now
                        // Check if HTTP is done - if so, we're truly finished
                        let connected = BASS_StreamGetFilePosition(self.decoderStream, DWORD(BASS_FILEPOS_CONNECTED))

                        if connected == 0 {
                            // HTTP done AND decoder buffer empty = track complete
                            let totalSeconds = Double(self.totalBytesPushed) / Double(self.sampleRate * self.channels * 4)
                            os_log(.info, log: self.logger, "✅ Decoder finished (ENDED + HTTP disconnected)")
                            os_log(.info, log: self.logger, "📊 Total decoded: %llu bytes (%.2f seconds of audio)", self.totalBytesPushed, totalSeconds)

                            if !self.manualStop {
                                os_log(.info, log: self.logger, "🎵 Track decode COMPLETE (natural end) - notifying delegate")
                                DispatchQueue.main.async {
                                    self.delegate?.audioStreamDecoderDidCompleteTrack(self)
                                }
                            } else {
                                os_log(.info, log: self.logger, "⏹️ Track decode stopped (manual skip)")
                            }
                            break
                        }

                        // HTTP still active - wait for more data to decode
                        // Rate limit logging to once per second to avoid log spam
                        let now = Date()
                        if now.timeIntervalSince(self.lastBufferEmptyLogTime) >= 1.0 {
                            os_log(.debug, log: self.logger, "⏳ Decoder buffer empty (HTTP still active), waiting...")
                            self.lastBufferEmptyLogTime = now
                        }
                        Thread.sleep(forTimeInterval: 0.01)
                        continue
                    }

                    // Real error (not ENDED)
                    os_log(.error, log: self.logger, "❌ Decoder stream error: %d", error)

                    // On error, notify delegate
                    if !self.manualStop {
                        DispatchQueue.main.async {
                            self.delegate?.audioStreamDecoderDidEncounterError(self, error: Int(error))
                        }
                    }
                    break
                }

                if bytesRead == 0 {
                    // CRITICAL: Like squeezelite opus.c:224-229
                    // bytesRead == 0 means decoder has no frames left to decode
                    // Check if HTTP stream is also disconnected (truly finished)
                    let connected = BASS_StreamGetFilePosition(self.decoderStream, DWORD(BASS_FILEPOS_CONNECTED))

                    if connected == 0 {
                        // Like squeezelite: n == 0 && stream.state <= DISCONNECT → return DECODE_COMPLETE
                        let totalSeconds = Double(self.totalBytesPushed) / Double(self.sampleRate * self.channels * 4)
                        os_log(.info, log: self.logger, "✅ Decoder finished (no more frames + HTTP disconnected)")
                        os_log(.info, log: self.logger, "📊 Total decoded: %llu bytes (%.2f seconds of audio)", self.totalBytesPushed, totalSeconds)

                        if !self.manualStop {
                            os_log(.info, log: self.logger, "🎵 Track decode COMPLETE (natural end) - notifying delegate")
                            DispatchQueue.main.async {
                                self.delegate?.audioStreamDecoderDidCompleteTrack(self)
                            }
                        } else {
                            os_log(.info, log: self.logger, "⏹️ Track decode stopped (manual skip)")
                        }
                        break
                    }

                    // Still connected - no data available yet, wait a bit (like squeezelite's usleep)
                    Thread.sleep(forTimeInterval: 0.001)
                    continue
                }

                // SQUEEZELITE-STYLE: Mark boundary when first chunk of new track is written
                // Like squeezelite: flac.c:176 - if (decode.new_stream) { output.track_start = outputbuf->writep; }
                // This ensures boundary is marked AFTER old decoder finishes pushing buffered audio
                if self.pendingTrackBoundary {
                    os_log(.info, log: self.logger, "🎯 First chunk of new track - marking boundary NOW at writep: %llu", self.totalBytesPushed)
                    self.markTrackBoundary()
                    self.pendingTrackBoundary = false

                    // Update trackStartPosition to the boundary we just marked
                    if let boundaryPos = self.trackBoundaryPosition {
                        self.trackStartPosition = boundaryPos
                        os_log(.info, log: self.logger, "🎯 Track start position updated to boundary: %llu (previous: %llu)", self.trackStartPosition, self.previousTrackStartPosition)
                    }
                }

                // Check if we should skip this data (drift correction)
                if self.skipAheadBytesRemaining > 0 {
                    // Discard this data - don't push to BASS
                    let bytesToDiscard = min(Int(bytesRead), self.skipAheadBytesRemaining)
                    self.skipAheadBytesRemaining -= bytesToDiscard

                    os_log(.debug, log: self.logger, "⏩ Discarding %d bytes (%.3f sec), %d bytes remaining to skip",
                           bytesToDiscard, Double(bytesToDiscard) / Double(self.sampleRate * self.channels * 4),
                           self.skipAheadBytesRemaining)

                    // Still track position even though we're not pushing to BASS
                    self.totalBytesPushed += UInt64(bytesRead)

                    // Continue to next loop iteration - don't push this data
                    continue
                }

                // Push decoded PCM to push stream (like squeezelite's write_cb to outputbuf)
                let pcmData = Data(bytes: &buffer, count: Int(bytesRead))
                let pushed = pcmData.withUnsafeBytes { ptr in
                    BASS_StreamPutData(
                        self.pushStream,
                        UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                        bytesRead
                    )
                }

                if pushed == DWORD.max {
                    let error = BASS_ErrorGetCode()
                    os_log(.error, log: self.logger, "❌ StreamPutData failed: %d", error)
                    break
                }

                // DIAGNOSTIC: Check what "queued" actually means
                // Per BASS docs: BASS_StreamPutData returns "amount of data currently queued"
                // Per BASS docs: BASS_ChannelGetData(BASS_DATA_AVAILABLE) returns "playback buffer level"
                let playbackBuffered = BASS_ChannelGetData(self.pushStream, nil, DWORD(BASS_DATA_AVAILABLE))
                let queuedAmount = Int(pushed)  // Return value from StreamPutData
                let totalBuffered = queuedAmount + Int(playbackBuffered)

                // Too spammy - uncomment only for debugging buffer levels
                // #if DEBUG
                // // Log buffer stats every ~2MB pushed (works with any chunk size)
                // let bytesSinceLastLog = self.totalBytesPushed - self.lastBufferDiagnosticBytes
                // if bytesSinceLastLog >= 2_000_000 {  // Every ~2MB
                //     os_log(.info, log: self.logger, "📊 BUFFER DIAGNOSTIC: playback=%d KB, queue=%d KB, total=%d KB (%.1f MB total)",
                //            playbackBuffered / 1024, queuedAmount / 1024, totalBuffered / 1024,
                //            Double(totalBuffered) / 1_048_576)
                //     self.lastBufferDiagnosticBytes = self.totalBytesPushed
                // }
                // #endif

                // SOFT THROTTLE: Slow down decoder when queue gets large
                // Hard limit (150 MB) is enforced by BASS_ATTRIB_PUSH_LIMIT
                // Soft limit (100 MB) triggers throttling to reduce CPU usage
                let softLimitBytes = 100_000_000  // 100 MB
                if queuedAmount > softLimitBytes {
                    // Queue is getting full - sleep to let playback consume buffer
                    // This prevents 100% CPU on long podcasts while maintaining smooth playback
                    // Log only every 50 throttles (~5 seconds) to avoid spam
                    self.throttleLogCounter += 1
                    if self.throttleLogCounter >= 50 {
                        os_log(.info, log: self.logger, "⏸️ Queue large (%.1f MB) - throttling decoder (logged every ~5s)", Double(queuedAmount) / 1_048_576)
                        self.throttleLogCounter = 0
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                    continue  // Skip to next loop iteration
                }

                // Reset throttle counter when not throttling
                self.throttleLogCounter = 0

                // Track total bytes for position calculation
                self.totalBytesPushed += UInt64(bytesRead)

                // Check if buffer ready for STMl signaling
                // FIX: Use totalBytesPushed instead of playbackBuffered
                // playbackBuffered is BASS's tiny internal buffer, not our push queue
                // totalBytesPushed tracks how much we've actually queued for playback
                if !self.sentSTMl && self.totalBytesPushed >= UInt64(self.bufferReadyThreshold) {
                    os_log(.info, log: self.logger, "📊 Buffer threshold reached (%llu bytes >= %d), signaling STMl",
                           self.totalBytesPushed, self.bufferReadyThreshold)
                    self.sentSTMl = true

                    // Notify delegate on main thread (server expects STMl before synchronized start)
                    DispatchQueue.main.async {
                        self.delegate?.audioStreamDecoderBufferReady(self)
                    }
                }
            }

            os_log(.info, log: self.logger, "🛑 Decoder loop stopped")

            // Clean up decoder stream
            if self.decoderStream != 0 {
                BASS_StreamFree(self.decoderStream)
                self.decoderStream = 0
            }
        }
    }

    // MARK: - Stream Info Update

    /// Update stream info from decoder stream (shows actual format: FLAC, MP3, etc.)
    private func updateStreamInfoFromDecoder(_ stream: HSTREAM) {
        guard stream != 0 else {
            audioPlayer?.currentStreamInfo = nil
            return
        }

        // Get channel info from BASS decoder stream
        var info = BASS_CHANNELINFO()
        guard BASS_ChannelGetInfo(stream, &info) != 0 else {
            os_log(.error, log: logger, "❌ Failed to get decoder stream info: %d", BASS_ErrorGetCode())
            return
        }

        // Get bitrate attribute from decoder stream
        var bitrate: Float = 0.0
        BASS_ChannelGetAttribute(stream, DWORD(BASS_ATTRIB_BITRATE), &bitrate)

        // Map ctype to human-readable format name
        let formatName = formatNameFromCType(info.ctype)

        // Extract bit depth from origres (LOWORD contains bits)
        let bitDepth = Int(info.origres & 0xFFFF)

        let streamInfo = AudioPlayer.StreamInfo(
            format: formatName,
            sampleRate: Int(info.freq),
            channels: Int(info.chans),
            bitDepth: bitDepth > 0 ? bitDepth : 16,  // Default to 16-bit if not specified
            bitrate: bitrate
        )

        audioPlayer?.currentStreamInfo = streamInfo
        os_log(.info, log: logger, "📊 Stream info: %{public}s", streamInfo.displayString)
    }

    private func formatNameFromCType(_ ctype: DWORD) -> String {
        // BASS codec type constants
        let BASS_CTYPE_STREAM_MP3: DWORD = 0x10005
        let BASS_CTYPE_STREAM_VORBIS: DWORD = 0x10002  // OGG Vorbis
        let BASS_CTYPE_STREAM_OPUS: DWORD = 0x11200    // From bassopus.h
        let BASS_CTYPE_STREAM_FLAC: DWORD = 0x10900    // From bassflac.h
        let BASS_CTYPE_STREAM_FLAC_OGG: DWORD = 0x10901  // FLAC in OGG container
        let BASS_CTYPE_STREAM_WAV: DWORD = 0x40000     // WAV format flag
        let BASS_CTYPE_STREAM_WAV_PCM: DWORD = 0x10001
        let BASS_CTYPE_STREAM_WAV_FLOAT: DWORD = 0x10003
        let BASS_CTYPE_STREAM_AIFF: DWORD = 0x10004
        let BASS_CTYPE_STREAM_CA: DWORD = 0x10007      // CoreAudio (AAC on iOS)

        // Check for WAV format flag first (0x40000 bit set)
        if (ctype & BASS_CTYPE_STREAM_WAV) != 0 {
            // Extract codec from LOWORD
            let codec = ctype & 0xFFFF
            switch codec {
            case 0x0001:  // WAVE_FORMAT_PCM
                return "WAV PCM"
            case 0x0003:  // WAVE_FORMAT_IEEE_FLOAT
                return "WAV Float"
            default:
                return "WAV (codec \(String(format: "0x%X", codec)))"
            }
        }

        switch ctype {
        case BASS_CTYPE_STREAM_MP3:
            return "MP3"
        case BASS_CTYPE_STREAM_VORBIS:
            return "OGG Vorbis"
        case BASS_CTYPE_STREAM_OPUS:
            return "Opus"
        case BASS_CTYPE_STREAM_FLAC:
            return "FLAC"
        case BASS_CTYPE_STREAM_FLAC_OGG:
            return "FLAC (OGG)"
        case BASS_CTYPE_STREAM_WAV_PCM:
            return "WAV PCM"
        case BASS_CTYPE_STREAM_WAV_FLOAT:
            return "WAV Float"
        case BASS_CTYPE_STREAM_AIFF:
            return "AIFF"
        case BASS_CTYPE_STREAM_CA:
            return "AAC"
        default:
            return "Unknown (\(String(format: "0x%X", ctype)))"
        }
    }

    /// Stop and cleanup push stream
    func cleanup() {
        os_log(.info, log: logger, "🧹 Cleaning up push stream")

        // Clear stream info when cleaning up
        audioPlayer?.currentStreamInfo = nil

        // Clean up sync start monitoring
        if isWaitingForSyncStart {
            os_log(.debug, log: logger, "🎯 Cleaning up synchronized start timer")
            stopSyncStartMonitoring()
            isWaitingForSyncStart = false
            syncStartJiffies = nil
        }

        // Stop decoding
        isDecoding = false
        stopDecoding()

        // Free stream (automatically removes all syncs/DSP/FX per BASS documentation)
        if pushStream != 0 {
            BASS_StreamFree(pushStream)
            pushStream = 0
        }

        // Clear our local sync arrays (syncs already removed by BASS_StreamFree)
        trackBoundarySyncs.removeAll()
        stallSync = 0  // Reset STALL sync handle (already freed by BASS_StreamFree)

        os_log(.info, log: logger, "✅ Cleanup complete")
    }

    // MARK: - Buffer Feeding

    /// Feed decoded PCM data to BASS buffer
    /// - Parameters:
    ///   - data: Decoded PCM audio data
    ///   - isNewTrack: Whether this marks the start of a new track
    func feedDecodedAudio(_ data: Data, isNewTrack: Bool) {
        guard pushStream != 0 else {
            os_log(.error, log: logger, "❌ Cannot feed data - no push stream")
            return
        }

        // If this is a new track, mark the boundary
        if isNewTrack {
            markTrackBoundary()
        }

        // Push decoded PCM data to BASS buffer
        let pushed = data.withUnsafeBytes { ptr in
            BASS_StreamPutData(
                pushStream,
                UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                UInt32(data.count)
            )
        }

        if pushed == DWORD.max {  // -1 in C unsigned = 0xFFFFFFFF
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ StreamPutData failed: %d", error)
        } else {
            os_log(.debug, log: logger, "📊 Pushed %d bytes to buffer", pushed)
        }

        // Monitor buffer health
        monitorBufferLevel()
    }

    /// Mark current buffer position as track boundary for gapless transition
    private func markTrackBoundary() {
        // CRITICAL FIX: Don't use write position - it's stale by the time sync is registered!
        // Instead, predict exactly when new track audio will start playing
        // Formula: current_playback_position + total_buffered_bytes

        let playbackPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
        let playbackBuffered = BASS_ChannelGetData(pushStream, nil, DWORD(BASS_DATA_AVAILABLE))
        let queuedAmount = Int(BASS_StreamPutData(pushStream, nil, 0))  // Get current queue size without adding data
        let totalBuffered = queuedAmount + Int(playbackBuffered)

        // EXACT: Boundary = when new track's first sample will be heard
        trackBoundaryPosition = UInt64(playbackPos + UInt64(totalBuffered))

        let boundarySeconds = Double(trackBoundaryPosition!) / Double(sampleRate * channels * 4)
        let playbackSeconds = Double(playbackPos) / Double(sampleRate * channels * 4)
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 🎯🎯🎯 TRACK BOUNDARY MARKED at PREDICTED position: %llu bytes (%.2f seconds)", trackBoundaryPosition!, boundarySeconds)
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 Current playback position: %llu bytes (%.2f seconds)", playbackPos, playbackSeconds)

        // Calculate how long until boundary is reached
        let bytesUntilBoundary = Int64(trackBoundaryPosition!) - Int64(playbackPos)
        let secondsUntilBoundary = Double(bytesUntilBoundary) / Double(sampleRate * channels * 4)
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 Playback will reach boundary in %.2f seconds (%lld bytes ahead)", secondsUntilBoundary, bytesUntilBoundary)

        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 BUFFER AT BOUNDARY MARK: playback=%d KB, queue=%d KB, total=%d KB (%.1f MB)",
               playbackBuffered / 1024, queuedAmount / 1024, totalBuffered / 1024, Double(totalBuffered) / 1_048_576)

        // This should now be accurate - boundary = current + buffer
        let predictedPlaybackTime = Double(playbackPos + UInt64(totalBuffered)) / Double(sampleRate * channels * 4)
        let driftPrediction = predictedPlaybackTime - boundarySeconds
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 🎯 PREDICTION: New audio should play at %.2f seconds (drift: %.3f sec)",
               predictedPlaybackTime, driftPrediction)

        // Set sync callback for this boundary
        // CRITICAL: Use BASS_SYNC_POS without MIXTIME so callback fires when audio is HEARD, not when mixed!
        // MIXTIME would fire ~0.5s early (when audio reaches mix buffer, ahead of playback)
        let sync = BASS_ChannelSetSync(
            pushStream,
            DWORD(BASS_SYNC_POS),  // Fire at playback time, not mixtime
            trackBoundaryPosition!,
            bassTrackBoundaryCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if sync != 0 {
            trackBoundarySyncs.append(sync)
            os_log(.error, log: logger, "[BOUNDARY-DRIFT] ✅ BASS sync callback registered for boundary position: %llu", trackBoundaryPosition!)
        } else {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "[BOUNDARY-DRIFT] ❌ Failed to set boundary sync! BASS error: %d", error)
        }
    }

    // MARK: - Buffer Monitoring

    /// Monitor buffer level and request more data if needed
    @discardableResult
    func monitorBufferLevel() -> Int {
        guard pushStream != 0 else { return 0 }

        let buffered = Int(BASS_ChannelGetData(pushStream, nil, DWORD(BASS_DATA_AVAILABLE)))

        // Calculate threshold (2 seconds of audio)
        let threshold = sampleRate * channels * 4 * 2  // 4 bytes per float, 2 seconds

        if buffered < threshold {
            os_log(.debug, log: logger, "⚠️ Buffer low: %d bytes (threshold: %d)", buffered, threshold)
            delegate?.audioStreamDecoderNeedsMoreData(self)
        }

        return buffered
    }

    /// Get detailed buffer statistics
    func getBufferStats() -> BufferStats {
        guard pushStream != 0 else {
            return BufferStats(bufferedBytes: 0, playbackPosition: 0, bufferPercentage: 0)
        }

        let buffered = Int(BASS_ChannelGetData(pushStream, nil, DWORD(BASS_DATA_AVAILABLE)))
        let position = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
        let percentage = min(100, Int((Double(buffered) / Double(maxBufferSize)) * 100))

        return BufferStats(
            bufferedBytes: buffered,
            playbackPosition: UInt64(position),
            bufferPercentage: percentage
        )
    }

    // MARK: - Track Boundary Handling

    /// Handle track boundary reached event (called from global callback)
    func handleTrackBoundary() {
        // Get current playback position to verify timing
        let playbackPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
        let playbackSeconds = Double(playbackPos) / Double(sampleRate * channels * 4)

        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 🎯🎯🎯 TRACK BOUNDARY REACHED - playback entered new track audio")
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 Playback position: %llu bytes (%.2f seconds)", playbackPos, playbackSeconds)

        if let boundaryPos = trackBoundaryPosition {
            let boundarySeconds = Double(boundaryPos) / Double(sampleRate * channels * 4)
            os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 Expected boundary: %llu bytes (%.2f seconds)", boundaryPos, boundarySeconds)

            // Log the difference (should be very close)
            let diff = Int64(playbackPos) - Int64(boundaryPos)
            let diffSeconds = Double(diff) / Double(sampleRate * channels * 4)
            os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 Timing accuracy: %lld bytes difference (%.3f seconds)", diff, diffSeconds)
        }

        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 Write position (totalBytesPushed): %llu bytes", totalBytesPushed)
        let writeReadGap = Int64(totalBytesPushed) - Int64(playbackPos)
        let writeReadGapSeconds = Double(writeReadGap) / Double(sampleRate * channels * 4)
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 Write-Read gap: %lld bytes (%.3f seconds ahead of playback)", writeReadGap, writeReadGapSeconds)

        // CRITICAL BUFFER ANALYSIS: Check buffer when STMs is about to be sent
        let playbackBuffered = BASS_ChannelGetData(pushStream, nil, DWORD(BASS_DATA_AVAILABLE))
        let queuedAmount = Int(BASS_StreamPutData(pushStream, nil, 0))  // Get current queue size without adding data
        let totalBuffered = queuedAmount + Int(playbackBuffered)
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 BUFFER AT STMs SEND: playback=%d KB, queue=%d KB, total=%d KB",
               playbackBuffered / 1024, queuedAmount / 1024, totalBuffered / 1024)

        // CRITICAL: Remove all OLD boundary syncs that have now fired
        // Only keep syncs for future boundaries (prevents stale callbacks)
        // Note: BASS_ChannelRemoveSync is safe to call even if sync already auto-removed
        let syncCount = trackBoundarySyncs.count
        for sync in trackBoundarySyncs {
            BASS_ChannelRemoveSync(pushStream, sync)
        }
        trackBoundarySyncs.removeAll()
        os_log(.info, log: logger, "[BOUNDARY-DRIFT] 🧹 Cleared %d old boundary sync(s)", syncCount)

        // trackStartPosition is already set to boundary position in startDecodingFromURL()
        // Don't update it here - it's already correct!
        // The boundary position IS the track start position

        // Notify delegate of track transition - THIS SENDS STMs!
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📡 ABOUT TO SEND STMs - notifying delegate now...")
        delegate?.audioStreamDecoderDidReachTrackBoundary(self)
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] ✅ STMs SENT - new track should start playing now")

        // Clear boundary marker - now getCurrentPosition() will calculate normally
        trackBoundaryPosition = nil

        os_log(.error, log: logger, "[BOUNDARY-DRIFT] ✅ Boundary handling complete")
    }

    /// Handle buffer end event (all audio has been played)
    /// This is where we start deferred tracks when format mismatch occurred
    func handleBufferEnd() {
        os_log(.info, log: logger, "🎵 Buffer end reached - checking for pending track")

        guard let pending = pendingTrack else {
            os_log(.info, log: logger, "📊 No pending track - buffer naturally ended")
            return
        }

        os_log(.info, log: logger, "🎵 Starting deferred track due to format mismatch")
        os_log(.info, log: logger, "📊 Deferred track: %{public}s (format: %{public}s)",
               pending.url, pending.format)

        // Clear pending track first
        pendingTrack = nil

        // Flush buffer and recreate stream with new format
        // Then start the deferred track
        startDeferredTrack(pending)
    }

    /// Start a track that was deferred due to format mismatch
    /// Uses existing decoder to preserve HTTP connection and get track from 0:00
    private func startDeferredTrack(_ track: PendingTrackInfo) {
        os_log(.error, log: logger, "[APP-RECOVERY] 🎵 STARTING DEFERRED TRACK (format mismatch recovery)")
        os_log(.error, log: logger, "[APP-RECOVERY] 📊 Using existing decoder: %{public}s", track.url)
        os_log(.error, log: logger, "[APP-RECOVERY] 📊 Mute state BEFORE stream recreation: muteNextStream=%{public}s", muteNextStream ? "TRUE" : "FALSE")

        // CRITICAL FIX: Clear sync wait state - deferred tracks are NOT synchronized starts
        // If we had a previous sync command, those flags are stale and will block playback
        if isWaitingForSyncStart {
            os_log(.info, log: logger, "[APP-RECOVERY] 🔄 Clearing stale sync wait state for deferred track")
            isWaitingForSyncStart = false
            syncStartJiffies = nil
            stopSyncStartMonitoring()
        }

        // CRITICAL FIX: Prevent STMl from being sent for deferred track starts
        // Deferred tracks send STMs immediately (not buffering for sync), so STMl would be invalid
        // Server expects: BUFFERING → STMl → wait → strm 'u' → PLAYING
        // Deferred track: start immediately → STMs → PLAYING (skip buffering phase)
        sentSTMl = true  // Pretend we already sent it to prevent buffer callback from firing

        // Update our format to match the new track
        sampleRate = track.sampleRate
        channels = track.channels
        currentFormat = track.format

        // Recreate push stream with new format
        // The buffer is now empty, so this is safe
        if pushStream != 0 {
            os_log(.error, log: logger, "[APP-RECOVERY] 🧹 Freeing old push stream before recreation")
            BASS_StreamFree(pushStream)
            pushStream = 0
        }

        os_log(.error, log: logger, "[APP-RECOVERY] 🔄 Initializing new push stream: %dHz, %dch", sampleRate, channels)
        initializePushStream(sampleRate: sampleRate, channels: channels)

        os_log(.error, log: logger, "[APP-RECOVERY] ▶️ Calling startPlayback() - should apply muting if muteNextStream=TRUE")
        startPlayback()

        // Use the EXISTING decoder (already connected, at position 0:00!)
        // This preserves the HTTP connection so we get the track from the beginning
        decoderStream = track.decoderStream

        // Mark as first track (new stream, starting fresh)
        trackStartPosition = 0
        previousTrackStartPosition = 0
        totalBytesPushed = 0
        lastBufferDiagnosticBytes = 0

        // Start decode loop with existing decoder
        isDecoding = true
        manualStop = false
        startDecoderLoop()

        // Notify delegate that deferred track started (for STMs)
        os_log(.error, log: logger, "[APP-RECOVERY] 📡 Notifying delegate of deferred track start")
        delegate?.audioStreamDecoderDidStartDeferredTrack(self)
    }

    // MARK: - Position Tracking

    /// Get current playback position within current track
    /// Returns PLAYBACK position (not decode position) - what's actually been played
    /// This matches squeezelite reporting frames_played (not frames_decoded)
    /// Position is relative to trackStartPosition (like squeezelite's output.track_start)
    func getCurrentPosition() -> TimeInterval {
        guard pushStream != 0 else { return 0 }

        // CRITICAL: Validate stream state before querying position
        // During route changes (CarPlay, AirPods, etc), stream may be in PAUSED_DEVICE or invalid state
        // Calling BASS_ChannelGetPosition() on corrupted streams returns garbage data
        // This garbage crashes iOS media UI (MPNowPlayingInfoCenter)
        let state = BASS_ChannelIsActive(pushStream)
        guard state == DWORD(BASS_ACTIVE_PLAYING) || state == DWORD(BASS_ACTIVE_PAUSED) else {
            os_log(.error, log: logger, "⚠️ Stream in invalid state (%d) - not querying position", state)
            return 0  // Safe fallback - don't query corrupted stream
        }

        // Get PLAYBACK position from BASS (not decode position!)
        // BASS_POS_BYTE gives playback position (what's actually played)
        // BASS_POS_DECODE would give decode position (ahead due to buffering)
        let playbackBytes = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))

        // Too spammy - uncomment only for debugging position calculations
        // #if DEBUG
        // os_log(.info, log: logger, "📊 POS: BASS playback=%llu trackStart=%llu prevStart=%llu boundary=%{public}s",
        //        playbackBytes, trackStartPosition, previousTrackStartPosition,
        //        trackBoundaryPosition.map { String($0) } ?? "none")
        // #endif

        // CRITICAL: For gapless, keep reporting OLD track's position until boundary crossed
        // When new track is queued, trackStartPosition is updated to the boundary position
        // But we shouldn't report "new track at 0 seconds" until playback actually reaches that boundary!
        // Instead, continue reporting position from the PREVIOUS track's start position
        if let boundaryPos = trackBoundaryPosition, playbackBytes < boundaryPos {
            // Still playing old track - calculate position from PREVIOUS track start
            // previousTrackStartPosition is saved before trackStartPosition gets updated to boundary

            // Protect against underflow
            guard playbackBytes >= previousTrackStartPosition else {
                os_log(.error, log: logger, "⚠️ Before boundary: playback (%llu) < previous start (%llu) - returning 0", playbackBytes, previousTrackStartPosition)
                return 0
            }

            let trackBytes = playbackBytes - previousTrackStartPosition
            let bytesPerSecond = sampleRate * channels * 4
            let seconds = Double(trackBytes) / Double(bytesPerSecond)
            let trackPosition = seconds + trackStartTimeOffset

            // Log "before boundary" position, but throttle to every 4 seconds to prevent duplicate spam
            let now = Date()
            if now.timeIntervalSince(lastBeforeBoundaryLogTime) >= 4.0 {
                os_log(.info, log: logger, "⏳ Before boundary (at %llu, boundary at %llu) - reporting old track position: %.2f (offset: %.2f)",
                       playbackBytes, boundaryPos, trackPosition, trackStartTimeOffset)
                lastBeforeBoundaryLogTime = now
            }

            return max(0, trackPosition)
        }

        // After boundary: Calculate position within NEW track (like squeezelite: position - track_start)
        // CRITICAL: Protect against underflow if playback position < trackStart
        // This can happen after buffer flush or on edge cases
        guard playbackBytes >= UInt64(trackStartPosition) else {
            os_log(.error, log: logger, "⚠️ Playback position (%llu) < track start (%llu) - returning 0", playbackBytes, trackStartPosition)
            return 0
        }

        let trackBytes = playbackBytes - UInt64(trackStartPosition)

        // Convert bytes to seconds
        // Float samples = 4 bytes per sample
        let bytesPerSecond = sampleRate * channels * 4  // 4 bytes per float sample
        let seconds = Double(trackBytes) / Double(bytesPerSecond)

        let trackPosition = seconds + trackStartTimeOffset
        return max(0, trackPosition)  // Ensure non-negative
    }

    /// Check if stream is currently playing
    func isPlaying() -> Bool {
        guard pushStream != 0 else { return false }
        return BASS_ChannelIsActive(pushStream) == DWORD(BASS_ACTIVE_PLAYING)
    }

    /// Check if we have a valid push stream (playing OR paused)
    func hasValidStream() -> Bool {
        guard pushStream != 0 else { return false }
        let state = BASS_ChannelIsActive(pushStream)
        return state == DWORD(BASS_ACTIVE_PLAYING) || state == DWORD(BASS_ACTIVE_PAUSED)
    }

    deinit {
        cleanup()
        #if DEBUG
        os_log(.info, log: logger, "AudioStreamDecoder deinitialized")
        #endif
    }
}

// MARK: - Supporting Types

/// Delegate for AudioStreamDecoder events
protocol AudioStreamDecoderDelegate: AnyObject {
    /// Called when buffer level is low and more data is needed
    func audioStreamDecoderNeedsMoreData(_ decoder: AudioStreamDecoder)

    /// Called when playback reaches a track boundary
    func audioStreamDecoderDidReachTrackBoundary(_ decoder: AudioStreamDecoder)

    /// Called when decoder completes a track naturally (like squeezelite's DECODE_COMPLETE → STMd)
    /// This means the track finished decoding naturally (not manual skip)
    func audioStreamDecoderDidCompleteTrack(_ decoder: AudioStreamDecoder)

    /// Called when decoder encounters an error
    func audioStreamDecoderDidEncounterError(_ decoder: AudioStreamDecoder, error: Int)

    /// Called when a deferred track (from format mismatch) starts playing
    /// This allows coordinator to send STMs notification to server
    func audioStreamDecoderDidStartDeferredTrack(_ decoder: AudioStreamDecoder)

    /// Called when buffer reaches ready threshold (PHASE 7.7)
    /// This allows coordinator to send STMl notification to server for sync readiness
    func audioStreamDecoderBufferReady(_ decoder: AudioStreamDecoder)
}

/// Buffer statistics
struct BufferStats {
    let bufferedBytes: Int
    let playbackPosition: UInt64
    let bufferPercentage: Int
}

/// Track metadata for boundary updates
struct TrackMetadata {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}
