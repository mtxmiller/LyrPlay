// File: AudioStreamDecoder.swift
// Buffer-level gapless playback implementation using BASS push streams
// Based on squeezelite's proven architecture
import Foundation
import AVFoundation
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

    /// Read-only handle for FFT sampling (visualizer). Returns 0 when no push
    /// stream is active.
    var activePushStream: HSTREAM { pushStream }

    /// Current push stream playback position in bytes (for SyncController self-decay).
    /// Returns 0 if no active stream.
    func pushStreamPositionBytes() -> UInt64 {
        guard pushStream != 0 else { return 0 }
        return BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
    }

    /// Nominal bytes per second (sampleRate × channels × 4 for float32). For SyncController.
    var nominalBytesPerSecond: Int { sampleRate * channels * 4 }

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
    /// Guarded by stateLock — written by the control plane, read by the loop.
    private var isDecoding: Bool = false

    /// Flag to track if decoder was manually stopped (vs natural completion)
    /// Guarded by stateLock.
    private var manualStop: Bool = false

    /// Guards decoder state shared between the control plane and the decode
    /// loop: decodeGeneration, isDecoding, manualStop, skipAheadBytesRemaining,
    /// and the write-position math (totalBytesPushed + the boundary fields
    /// flushBuffer resets). bd LMS_StreamTest-433.2.2.
    private let stateLock = NSLock()

    /// Bumped by every startDecodingFromURL/stopDecoding. A queued start or a
    /// running decode loop whose captured generation no longer matches has
    /// been superseded and must exit without touching current-generation
    /// state. Guarded by stateLock.
    private var decodeGeneration: Int = 0

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

    /// Maximum total buffer (playback + queue) before throttling decoder.
    /// Squeezelite uses ~10s but runs on LAN. We need cellular dead spot resilience.
    /// 30 seconds at 48kHz stereo float32 = 48000 * 2 * 4 * 30 = 11,520,000 bytes (~11MB).
    /// Tradeoff: STMd fires ~30s before track end (vs 260s before with old unbounded queue).
    private let maxBufferSize: Int = 11_520_000

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

    /// Pending replay gain for next track (like squeezelite's output.next_replay_gain)
    /// Stored when gapless preload arrives, applied when playback reaches the track boundary
    private var pendingReplayGain: Float?

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
    private var isWaitingForUnpause: Bool = false

    // MARK: - Measured Bitrate (BASS_FILEPOS_DOWNLOAD-based)

    /// Sample of HTTP-download progress on `decoderStream`. Used to compute
    /// the actual on-the-wire bitrate over a moving window — codec-agnostic,
    /// unlike `BASS_ATTRIB_BITRATE` which BASSFLAC and BASSOPUS don't report
    /// usefully. The LMS `r` tag is also wrong for transcoded streams (it's
    /// the source file's bitrate; e.g. "2830kbps" for a FLAC transcoded down
    /// to Opus). See `Architecture/Stream Start Coordination.md`.
    private struct BitrateSample {
        let bytes: UInt64
        let timestamp: TimeInterval
    }
    private var bitrateSamples: [BitrateSample] = []
    private var bitrateMeasurementStart: TimeInterval?
    /// Window over which we compute the average download rate. Long enough to
    /// smooth VBR frame-to-frame variance; short enough to feel responsive on
    /// bitrate changes (e.g., when the user re-selects audio format mid-stream).
    private let bitrateMeasurementWindow: TimeInterval = 10.0
    /// BASS pre-fills its HTTP buffer at network speed, so the first few
    /// seconds of download rate is much higher than the encoded bitrate.
    /// After the buffer is full, BASS throttles to match decoder consumption,
    /// which equals the encoded bitrate.
    private let bitrateInitialIgnore: TimeInterval = 3.0

    /// Called by SlimProtoCoordinator's 1Hz heartbeat. Returns a measured
    /// bitrate string formatted like LMS's `r` tag (e.g. "192kbps" or
    /// "192kbps VBR"), or nil if a stable measurement isn't yet available.
    /// Coordinator passes the result to AudioPlayer.applyMeasuredBitrate;
    /// nil clears the measured override and the LMS server value (if any)
    /// shows through as the fallback.
    func sampleMeasuredBitrate() -> String? {
        guard decoderStream != 0 else { return nil }

        let now = ProcessInfo.processInfo.systemUptime
        let bytes = BASS_StreamGetFilePosition(decoderStream, DWORD(BASS_FILEPOS_DOWNLOAD))

        // BASS returns -1 (= UInt64.max) when the file-position interface isn't
        // implemented for this stream — e.g., some remote-stream protocols.
        // Return nil so the LMS-reported value can show through.
        guard bytes != UInt64.max else { return nil }

        // First sample anchors the measurement window.
        if bitrateMeasurementStart == nil {
            bitrateMeasurementStart = now
            bitrateSamples = [BitrateSample(bytes: bytes, timestamp: now)]
            return nil
        }

        bitrateSamples.append(BitrateSample(bytes: bytes, timestamp: now))

        // Trim to the moving window.
        let cutoff = now - bitrateMeasurementWindow
        bitrateSamples.removeAll { $0.timestamp < cutoff }

        // Suppress during the initial prefetch burst — accumulate samples so
        // we have history when we cross the threshold, but don't publish.
        guard now - (bitrateMeasurementStart ?? now) > bitrateInitialIgnore else {
            return nil
        }

        guard let first = bitrateSamples.first,
              let last = bitrateSamples.last,
              last.timestamp - first.timestamp > 1.0,
              last.bytes > first.bytes else {
            return nil
        }

        let deltaBytes = Double(last.bytes - first.bytes)
        let deltaTime = last.timestamp - first.timestamp
        let kbps = Int((deltaBytes * 8.0 / 1000.0) / deltaTime)

        // Sanity bound — pathological values point at math/wraparound bugs,
        // not a real bitrate.
        guard kbps > 0, kbps < 100_000 else { return nil }

        let isVBR = detectVBR(samples: bitrateSamples)
        return isVBR ? "\(kbps)kbps VBR" : "\(kbps)kbps"
    }

    /// Estimate VBR via coefficient of variation across the per-sample
    /// instantaneous rates. CBR streams hold a steady byte-per-second rate
    /// (CV ~= 0); VBR streams vary 10-30% by content complexity.
    private func detectVBR(samples: [BitrateSample]) -> Bool {
        guard samples.count >= 4 else { return false }
        var rates: [Double] = []
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let curr = samples[i]
            let dt = curr.timestamp - prev.timestamp
            guard dt > 0.5, curr.bytes > prev.bytes else { continue }
            rates.append(Double(curr.bytes - prev.bytes) / dt)
        }
        guard rates.count >= 3 else { return false }
        let mean = rates.reduce(0, +) / Double(rates.count)
        guard mean > 0 else { return false }
        let variance = rates.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rates.count)
        let cv = variance.squareRoot() / mean
        return cv > 0.10
    }

    private func resetBitrateMeasurement() {
        bitrateSamples.removeAll()
        bitrateMeasurementStart = nil
    }

    // MARK: - Buffer Skip Ahead for Multi-Room Audio

    /// Number of bytes remaining to skip (for drift correction when player is behind).
    /// Decoder loop checks this and discards data instead of pushing to BASS.
    /// Note: effect is delayed by the BASS push-queue depth (currently ~30s headroom
    /// for cellular resilience). Server-side skipAhead corrections will be slow to
    /// take effect — this is the trade-off documented in the sync drift plan.
    private var skipAheadBytesRemaining: Int = 0

    // MARK: - PauseForInterval for sync correction (Fix 2 in sync drift plan)

    /// Pending BASS_ChannelStart work item for sync-correction pauseForInterval.
    /// Cancelled when superseded by stop/flush/another pause/unpause/skipAhead/free.
    private var pendingResumeWorkItem: DispatchWorkItem?

    /// Generation counter for pendingResumeWorkItem. Defends against BASS handle
    /// reuse: after BASS_StreamFree, the same DWORD value may be allocated to a
    /// new stream. Incrementing this counter on cancel/free invalidates any
    /// in-flight closure even if it already passed the cancel check.
    private var pauseGeneration: Int = 0

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
        isWaitingForUnpause = true

        // Start monitoring timer (check every 100ms like AudioPlayer)
        startSyncStartMonitoring(targetJiffies: targetJiffies)
    }

    /// Pre-set the sync-waiting flag, called when the server's 'strm s' command has
    /// autostart='0' or '2' (= "wait for unpause"). This prevents `flushBuffer()` and
    /// `startPlayback()` from calling BASS_ChannelPlay before the matching 'u' command
    /// arrives with synchronized jiffies. Without this, BASS plays ~300ms of audio
    /// during the 's' → 'u' gap, putting us ahead of squeezelite peers at sync start.
    func markUnpausePending() {
        isWaitingForUnpause = true
        os_log(.info, log: logger, "🎯 Sync start pending (autostart='0'/'2') — will wait for u command")
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
                self.isWaitingForUnpause = false
                self.syncStartJiffies = nil
                self.stopSyncStartMonitoring()

                // Now actually start BASS playback
                guard self.pushStream != 0 else {
                    os_log(.error, log: self.logger, "❌ Cannot start - no push stream")
                    return
                }

                // === [SYNC-DIAG] Pre-Start snapshot ===========================
                let scheduleSkew = currentJiffies - targetJiffies
                let posBytesBefore = BASS_ChannelGetPosition(self.pushStream, DWORD(BASS_POS_BYTE))
                let posSecBefore = BASS_ChannelBytes2Seconds(self.pushStream, posBytesBefore)
                let queueBytes = BASS_StreamPutData(self.pushStream, nil, 0)
                let playbackBufBytes = BASS_ChannelGetData(self.pushStream, nil, DWORD(BASS_DATA_AVAILABLE))
                #if os(iOS)
                let halLatency = AVAudioSession.sharedInstance().outputLatency
                #else
                let halLatency = 0.0
                #endif
                let bytesPerSec = Double(self.sampleRate * self.channels * 4)
                let queueSec = Double(queueBytes) / bytesPerSec
                let pbBufSec = (playbackBufBytes == DWORD.max) ? 0 : Double(playbackBufBytes) / bytesPerSec
                os_log(.info, log: self.logger,
                       "[SYNC-DIAG] pre-start: schedule_skew=%.3fms, pos=%.3fs (%llu B), push_queue=%.3fs (%u B), playback_buf=%.3fs (%u B), HAL=%.3fs, total_pipeline=%.3fs",
                       scheduleSkew * 1000, posSecBefore, posBytesBefore,
                       queueSec, queueBytes, pbBufSec, playbackBufBytes,
                       halLatency, queueSec + pbBufSec + halLatency)
                let wallAtStart = Date()
                // ============================================================

                let result = BASS_ChannelPlay(self.pushStream, 0)

                if result != 0 {
                    // Apply muting if needed (for silent recovery)
                    if self.muteNextStream {
                        BASS_ChannelSetAttribute(self.pushStream, DWORD(BASS_ATTRIB_VOLDSP), 0.001)
                        os_log(.info, log: self.logger, "🔇 DSP gain = 0.001 (synchronized start with muting)")
                    }

                    os_log(.info, log: self.logger, "✅ Synchronized playback started successfully (muted: %{public}s)", self.muteNextStream ? "YES" : "NO")
                    self.delegate?.audioStreamDecoderDidStartPlayback(self)

                    // === [SYNC-DIAG] Post-Start +1s snapshot ===================
                    // Re-read position 1s after BASS_ChannelPlay so we can compute
                    // the effective playback rate during the first second of resumed
                    // audio. If rate < nominal, there's a startup gap during which
                    // BASS hadn't fully spun up but jiffies still advanced — which is
                    // the cause we're hunting.
                    let myStream = self.pushStream
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self = self else { return }
                        guard self.pushStream != 0, self.pushStream == myStream else { return }
                        let posBytesAfter = BASS_ChannelGetPosition(self.pushStream, DWORD(BASS_POS_BYTE))
                        let wallElapsed = Date().timeIntervalSince(wallAtStart)
                        let bytesAdvanced = (posBytesAfter >= posBytesBefore) ? (posBytesAfter - posBytesBefore) : 0
                        let observedBps = Double(bytesAdvanced) / wallElapsed
                        let effectiveRate = observedBps / bytesPerSec
                        let queueAfter = BASS_StreamPutData(self.pushStream, nil, 0)
                        let pbBufAfter = BASS_ChannelGetData(self.pushStream, nil, DWORD(BASS_DATA_AVAILABLE))
                        os_log(.info, log: self.logger,
                               "[SYNC-DIAG] +%.3fs after start: bytes_advanced=%llu (expected %.0f), effective_rate=%.4fx, push_queue=%u B, playback_buf=%u B",
                               wallElapsed, bytesAdvanced, bytesPerSec * wallElapsed,
                               effectiveRate, queueAfter, pbBufAfter)
                    }
                    // ============================================================
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

    // MARK: - PauseForInterval for Multi-Room Audio (Fix 2 in sync drift plan)

    /// Pause the push stream for `duration` seconds, then resume.
    /// Server uses this (strm 'p' with non-zero interval) to slow down a player that's
    /// ahead of the sync group. BASS_ChannelPause freezes BASS_POS_BYTE; the iOS HAL
    /// ring drains for outputLatency (~16ms typical) then speaker silent. After
    /// `duration` wall time, BASS_ChannelStart resumes from the same music position.
    /// Apparent stream start time on the server shifts forward by `duration`,
    /// matching reference player.
    ///
    /// Replaces the previous BASS_StreamPutData(silence) approach which appended silence
    /// to the END of the queue (no effect on currently-playing music — Bug 3).
    func playSilence(duration: TimeInterval) {
        guard pushStream != 0 else {
            os_log(.error, log: logger, "❌ Cannot pauseForInterval - no push stream")
            return
        }
        guard duration > 0 else {
            os_log(.info, log: logger, "🔇 Zero duration pauseForInterval - skipping")
            return
        }

        // Supersede any existing pause window
        pendingResumeWorkItem?.cancel()

        // Treat PLAYING and PAUSED as both valid entry states for pauseForInterval:
        // - PLAYING: pause now, schedule resume.
        // - PAUSED: already paused (e.g. a prior pauseForInterval is still in window
        //   and was just superseded by us cancelling its resume); skip the redundant
        //   pause call but still schedule a new resume so the stream doesn't strand
        //   paused forever. Without this branch, BASS_ChannelPause returns FALSE on
        //   an already-paused stream (BASS_ERROR_NOPLAY) and we'd bail without
        //   scheduling resume — silent failure mode if the server ever rapid-fires
        //   sync corrections.
        let state = BASS_ChannelIsActive(pushStream)
        switch state {
        case DWORD(BASS_ACTIVE_PLAYING):
            BASS_ChannelPause(pushStream)
            os_log(.info, log: logger, "⏸️🔇 BASS_ChannelPause for %.3f seconds (drift correction)", duration)
        case DWORD(BASS_ACTIVE_PAUSED):
            os_log(.info, log: logger, "⏸️🔇 Already paused — extending pause window for %.3f seconds (supersede)", duration)
        default:
            // STOPPED or STALLED — nothing to pause, nothing to schedule.
            os_log(.info, log: logger, "playSilence: stream not playing/paused (state=%d), skipping", state)
            return
        }

        pauseGeneration += 1
        let myGeneration = pauseGeneration
        let myStream = pushStream

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Generation guard: if cancelPendingResume() ran (e.g., stop/flush/free),
            // it incremented pauseGeneration. Bail if our generation is stale.
            guard self.pauseGeneration == myGeneration else {
                os_log(.info, log: self.logger, "⏸️→▶️ Resume skipped — generation mismatch (cancelled)")
                return
            }
            // Stream identity guard: BASS_StreamFree may have freed our handle and
            // BASS may have reused the DWORD for a new stream. Don't start the wrong stream.
            guard self.pushStream != 0, self.pushStream == myStream else {
                os_log(.info, log: self.logger, "⏸️→▶️ Resume skipped — stream handle changed")
                return
            }
            BASS_ChannelStart(self.pushStream)
            os_log(.info, log: self.logger, "▶️ Resumed after pauseForInterval")
        }
        pendingResumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    /// Cancel any pending resume scheduled by playSilence().
    /// Called by stop/flush/skipAhead/unpause/freeStream paths to prevent
    /// a stale BASS_ChannelStart firing after the stream has changed state.
    func cancelPendingResume() {
        if pendingResumeWorkItem != nil {
            pendingResumeWorkItem?.cancel()
            pendingResumeWorkItem = nil
            // Invalidate any in-flight closure that may have already passed the cancel check.
            pauseGeneration += 1
            os_log(.debug, log: logger, "🚫 Cancelled pending resume work item")
        }
    }

    // MARK: - Rate Matching for Multi-Room Audio Drift Correction

    /// Slide BASS_ATTRIB_FREQ to apply a small playback-rate offset.
    /// Used by SyncController for sub-100ms drift corrections — inaudible at ±0.5%.
    /// - Parameter offsetPct: fraction (e.g. 0.005 = +0.5%, -0.005 = -0.5%). Pass 0 to return to nominal.
    func setRateOffsetPct(_ offsetPct: Double) {
        guard pushStream != 0 else { return }
        let newFreq = Float(Double(sampleRate) * (1.0 + offsetPct))
        let result = BASS_ChannelSlideAttribute(pushStream, DWORD(BASS_ATTRIB_FREQ), newFreq, DWORD(SyncControllerConstants.slideDurationMs))
        if result == 0 {
            os_log(.error, log: logger, "❌ SlideAttribute FREQ failed: %d", BASS_ErrorGetCode())
        }
    }

    /// Snap BASS_ATTRIB_FREQ immediately (no slide). Used by SyncController.reset()
    /// on stream recreate / reconnect where a smooth glissando would be the wrong shape.
    func setRateOffsetPctImmediate(_ offsetPct: Double) {
        guard pushStream != 0 else { return }
        let newFreq = Float(Double(sampleRate) * (1.0 + offsetPct))
        BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_FREQ), newFreq)
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

        // Set the skip counter - decoder loop will discard this many bytes.
        // skipAhead is called from the control plane while the loop runs on
        // decodeQueue, so the counter is guarded by stateLock.
        stateLock.lock()
        skipAheadBytesRemaining = bytesToSkip
        stateLock.unlock()

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

        #if os(iOS)
        // CRITICAL: Set iOS audio session rate to match content for bit-perfect playback
        // Per Ian @ un4seen (topic 20831): Use AVAudioSession.setPreferredSampleRate
        // "BASS will also detect when the output rate is changed" via this method
        // This is the RECOMMENDED approach for iOS instead of BASS_DEVICE_REINIT
        // Called HERE (not during prefetch) so sample rate changes only when stream is actually recreated
        do {
            let session = AVAudioSession.sharedInstance()
            let currentRate = session.sampleRate

            if Int(currentRate) != sampleRate {
                os_log(.info, log: logger, "🔄 iOS session rate (%.0fHz) != stream rate (%dHz) - updating for bit-perfect playback", currentRate, sampleRate)

                // Set preferred sample rate - iOS will honor this for external DACs
                // Built-in speakers may remain locked at 48kHz (hardware limitation)
                try session.setPreferredSampleRate(Double(sampleRate))

                // BASS automatically detects the rate change - verify what we got
                var deviceInfo = BASS_INFO()
                if BASS_GetInfo(&deviceInfo) != 0 {
                    let finalRate = Int(deviceInfo.freq)
                    let actualIOSRate = Int(session.sampleRate)

                    if finalRate == sampleRate && actualIOSRate == sampleRate {
                        os_log(.info, log: logger, "✅ Bit-perfect playback: %.0fHz → %dHz (iOS session + BASS device)", currentRate, finalRate)
                    } else if actualIOSRate == sampleRate {
                        os_log(.info, log: logger, "✅ iOS session at %dHz (BASS shows %dHz)", actualIOSRate, finalRate)
                    } else {
                        os_log(.info, log: logger, "ℹ️ Device limited to %dHz (iOS: %dHz) - audio will be resampled from %dHz", finalRate, actualIOSRate, sampleRate)
                    }
                }
            } else {
                os_log(.debug, log: logger, "✅ iOS session rate matches stream: %.0fHz (bit-perfect)", currentRate)
            }
        } catch {
            os_log(.error, log: logger, "❌ Failed to set preferred sample rate: %{public}s", error.localizedDescription)

            // Still check BASS device rate for logging
            var deviceInfo = BASS_INFO()
            if BASS_GetInfo(&deviceInfo) != 0 {
                os_log(.info, log: logger, "ℹ️ Continuing with BASS device at %dHz", Int(deviceInfo.freq))
            }
        }
        #endif

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

        // Safety net: BASS hard limit on queue (above our throttle target)
        // Throttle targets ~30s (11.5MB), this is a backstop at ~50MB
        let hardLimitBytes: Float = 50_000_000  // 50 MB
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

        // SyncController hook (D4): fresh stream → reset rate offset & drift residual.
        // Marshal to main so the controller's main-thread invariant holds.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioStreamDecoderDidRecreatePushStream(self)
        }
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
        if isWaitingForUnpause {
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
            // The control plane is main-confined (bd 433.2.1). Keep the call
            // synchronous when already on main — the deferred-STMs handshake
            // relies on the callback firing in the same turn as ChannelPlay —
            // and marshal when called from decodeQueue (format-mismatch path).
            if Thread.isMainThread {
                delegate?.audioStreamDecoderDidStartPlayback(self)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.audioStreamDecoderDidStartPlayback(self)
                }
            }
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

        // After AVAudioSession interruption (phone call) or route change, BASS may leave
        // the output device in BASS_ACTIVE_PAUSED_DEVICE. BASS_ChannelPlay then succeeds
        // but produces no audio. BASS docs: "BASS_Start can be used to force resumption."
        let wasStarted = BASS_IsStarted()
        BASS_Start()
        os_log(.info, log: logger, "🔊 BASS_Start before resume (was started: %{public}s)", wasStarted != 0 ? "YES" : "NO")

        let result = BASS_ChannelPlay(pushStream, 0)
        if result != 0 {
            os_log(.error, log: logger, "[APP-RECOVERY] ✅ Push stream resumed successfully (muted: %{public}s)", muteNextStream ? "YES" : "NO")
            delegate?.audioStreamDecoderDidStartPlayback(self)
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

    /// Restore DSP gain after silent recovery (respects active ReplayGain)
    func restoreDSPGain() {
        guard pushStream != 0 else { return }

        BASS_ChannelSetAttribute(pushStream, DWORD(BASS_ATTRIB_VOLDSP), currentReplayGain)
        os_log(.info, log: logger, "🔊 APP OPEN RECOVERY: DSP gain restored to %.4f (ReplayGain-aware)", currentReplayGain)
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
        // Clamp to safe range — squeezelite doesn't clamp at this stage,
        // but we cap at 4.0 (~+12dB) to prevent extreme amplification
        let clampedGain = min(max(gain, 0.0), 4.0)
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
        // Claim a generation slot NOW (caller order defines supersession),
        // then do the blocking work on decodeQueue — BASS_StreamCreateURL is
        // a synchronous HTTP connect (up to BASS NET_TIMEOUT ~5s) and must
        // never stall the main thread (bd LMS_StreamTest-433.2.2).
        stateLock.lock()
        decodeGeneration += 1
        let generation = decodeGeneration
        stateLock.unlock()

        // Store the track start time offset SYNCHRONOUSLY (pre-433.2.2 timing).
        // Position reporting (getCurrentPosition → STAT elapsed → server time →
        // lock screen) adds this offset; if it were set inside the async
        // performStartDecoding, heartbeats in the window until
        // BASS_StreamCreateURL completes would report the OLD track's offset
        // against a flushed stream, making the displayed time hunt around
        // after a playlist-jump seek (bd LMS_StreamTest-egd).
        trackStartTimeOffset = startTime

        decodeQueue.async { [weak self] in
            self?.performStartDecoding(url, format: format, isNewTrack: isNewTrack,
                                       startTime: startTime, replayGain: replayGain,
                                       generation: generation)
        }
    }

    /// Runs on decodeQueue. The decode loop executes inline at the end, so
    /// the serial queue naturally orders: [start A][loop A][start B][loop B] —
    /// a superseded start bails at the generation check, and a superseded
    /// loop exits within one iteration and frees only its own stream.
    private func performStartDecoding(_ url: String, format: String, isNewTrack: Bool, startTime: Double, replayGain: Float, generation: Int) {
        stateLock.lock()
        let superseded = (generation != decodeGeneration)
        stateLock.unlock()
        guard !superseded else {
            os_log(.info, log: logger, "⏭️ Skipping superseded decode start for %{public}s", url)
            return
        }

        os_log(.info, log: logger, "🎵 Starting decoder for %{public}s: %{public}s (startTime: %.2f, replayGain: %.4f)", format, url, startTime, replayGain)

        // Reset measured-bitrate state — new track means a new decoder stream
        // with a new BASS_FILEPOS_DOWNLOAD counter starting at 0.
        resetBitrateMeasurement()

        // Reset STMl flag for new track
        sentSTMl = false
        os_log(.info, log: logger, "🎯 Reset sentSTMl flag for new track")

        // Server sends 0.0 when track has no ReplayGain metadata — treat as unity (1.0)
        let effectiveGain = (replayGain > 0.0) ? replayGain : 1.0

        if isNewTrack {
            // Gapless: defer gain until playback reaches the track boundary
            // Like squeezelite's output.next_replay_gain (slimproto.c:384)
            // Current track keeps playing with currentReplayGain until boundary fires
            pendingReplayGain = effectiveGain
            os_log(.info, log: logger, "🎚️ ReplayGain deferred for gapless: pending=%.4f (current=%.4f)", effectiveGain, currentReplayGain)
        } else {
            // Non-gapless (first track / skip): apply immediately, buffer was flushed
            pendingReplayGain = nil
            setReplayGain(effectiveGain)
        }

        // (trackStartTimeOffset is set synchronously in startDecodingFromURL —
        // see bd LMS_StreamTest-egd)

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

        // NOTE: Don't update stream info here! This happens during PREFETCHING.
        // Stream info is updated when track actually starts (just before runDecoderLoop).
        // Updating here would show the NEXT track's sample rate while CURRENT track plays.

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

            // Not gapless - safe to recreate stream immediately, here on
            // decodeQueue (initializePushStream's AVAudioSession sample-rate
            // call is blocking and must stay off main; startPlayback marshals
            // its own delegate callback to main).
            os_log(.error, log: logger, "⚠️ Format mismatch! Recreating push stream to match decoder")

            // Update our stored format
            sampleRate = actualSampleRate
            channels = actualChannels

            // Recreate push stream with correct format
            if pushStream != 0 {
                cancelPendingResume()  // Stream identity changes; invalidate any pending resume.
                BASS_StreamFree(pushStream)
            }

            initializePushStream(sampleRate: sampleRate, channels: channels)
            _ = startPlayback()
        }

        // ONE critical section: re-check the generation (a stopDecoding/new
        // start may have landed while BASS_StreamCreateURL was blocking),
        // mark position tracking (flushBuffer on the control plane resets
        // these same fields), and claim the loop slot.
        stateLock.lock()
        let stillCurrent = (generation == decodeGeneration)
        if stillCurrent, pushStream != 0 {
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
        if stillCurrent {
            isDecoding = true
            manualStop = false  // This is a fresh start, not a manual stop
        } else {
            pendingTrackBoundary = false
        }
        stateLock.unlock()

        // If superseded, free the stream we just created — the newer start
        // is queued behind us on decodeQueue.
        guard stillCurrent else {
            os_log(.info, log: logger, "⏭️ Decode start superseded during stream creation — freeing")
            if decoderStream != 0 {
                BASS_StreamFree(decoderStream)
                decoderStream = 0
            }
            return
        }

        // Update stream info NOW (track is actually starting, not just buffering)
        updateStreamInfoFromDecoder(decoderStream)

        // Run the decoder loop inline (like squeezelite's decode_thread) —
        // decodeQueue serializes it against any queued starts.
        runDecoderLoop(generation: generation)
    }

    /// Stop current decoder stream
    func stopDecoding() {
        os_log(.info, log: logger, "⏹️ Stopping decoder (manual stop)")
        stateLock.lock()
        decodeGeneration += 1   // Supersede any queued start and running loop
        manualStop = true       // Mark as manual stop
        isDecoding = false
        stateLock.unlock()

        // Clean up sync start monitoring
        if isWaitingForUnpause {
            os_log(.debug, log: logger, "🎯 Canceling synchronized start due to manual stop")
            stopSyncStartMonitoring()
            isWaitingForUnpause = false
            syncStartJiffies = nil
        }

        // Clear pending replay gain (no boundary will fire after manual stop)
        pendingReplayGain = nil

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

        // Do NOT free decoderStream here: the decode loop owns its handle and
        // frees it on exit — it notices the generation bump within one
        // iteration (≤50ms). Freeing from here raced the loop's
        // BASS_ChannelGetData, and could free a NEWER stream created by a
        // start that was queued after this stop (bd LMS_StreamTest-433.2.2).
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
        // This resets both buffer contents AND position counter.
        // The reset and the write-position math must be one critical section:
        // the decode loop's push+count runs under the same lock, so a chunk
        // either lands fully before the flush (and is cleared with the
        // buffer) or is dropped by the loop's generation check — never
        // half-counted across the reset (bd LMS_StreamTest-433.2.2).
        stateLock.lock()
        BASS_ChannelSetPosition(pushStream, 0, DWORD(BASS_POS_BYTE))

        // Sync mode: don't restart playback here — the sync timer (after 'u' arrives)
        // is responsible for the actual BASS_ChannelPlay. Calling it here would start
        // BASS playing ~300ms before the synchronized start fires, putting us ahead
        // of squeezelite peers in the sync group.
        //
        // CRITICAL: We must also explicitly PAUSE BASS. Coming from a previous track,
        // the channel is in BASS_ACTIVE_PLAYING state — SetPosition(0) clears the queue
        // contents but leaves the channel in PLAYING state, so as soon as the decoder
        // pushes new data BASS consumes it. Pausing here gives a guaranteed STOPPED-or-
        // PAUSED state until the sync timer's BASS_ChannelPlay() fires.
        if isWaitingForUnpause {
            BASS_ChannelPause(pushStream)
            trackStartPosition = 0
            previousTrackStartPosition = 0
            trackBoundaryPosition = nil
            totalBytesPushed = 0
            lastBufferDiagnosticBytes = 0
            stateLock.unlock()
            let stateAfter = BASS_ChannelIsActive(pushStream)
            os_log(.info, log: logger, "🧹 Buffer cleared + BASS paused (state=%d), playback deferred to sync timer", stateAfter)
            return
        }

        // Method 2: Restart to clear the buffer
        // BASS_ChannelPlay with restart=TRUE clears buffer contents
        // Trust BASS to handle device switching automatically
        let result = BASS_ChannelPlay(pushStream, 1)  // 1 = restart (clears buffer)
        if result != 0 {
            trackStartPosition = 0  // Reset track start for position calculation
            previousTrackStartPosition = 0
            trackBoundaryPosition = nil  // Clear old gapless boundary from previous track
            totalBytesPushed = 0  // Reset write position
            lastBufferDiagnosticBytes = 0  // Reset buffer diagnostic counter
        }
        stateLock.unlock()

        if result != 0 {
            // Verify position was reset
            let newPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
            os_log(.info, log: logger, "📊 BASS position AFTER flush: %llu (should be 0)", newPos)
            os_log(.info, log: logger, "✅ Buffer flushed and restarted - BASS auto-handled device switching")
        } else {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Failed to flush buffer: error %d", error)
        }
    }

    /// Loop-continuation check, taken once per iteration under stateLock.
    private func shouldContinueDecoding(generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isDecoding && generation == decodeGeneration
    }

    /// manualStop read for the loop's exit paths (guarded by stateLock).
    private func wasManuallyStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return manualStop
    }

    /// Decoder loop - pulls PCM from decoder stream and pushes to push stream
    /// This matches squeezelite's decode_thread() architecture.
    /// Runs INLINE on decodeQueue (from performStartDecoding /
    /// startDeferredTrack), so the serial queue orders loops against queued
    /// starts. Exits within one iteration when its generation is superseded,
    /// and its exit cleanup is the only place the active decoder stream is
    /// freed (bd LMS_StreamTest-433.2.2).
    private func runDecoderLoop(generation: Int) {
            os_log(.info, log: self.logger, "🔄 Decoder loop started")

            // Snapshot for no-progress timeout: detect streams that never produce audio
            let loopStartTime = Date()
            let bytesAtLoopStart = self.totalBytesPushed

            // Buffer for decoded PCM (4KB chunks like squeezelite)
            let bufferSize = 4096
            var buffer = [Float](repeating: 0, count: bufferSize)

            while self.shouldContinueDecoding(generation: generation) && self.decoderStream != 0 {
                // Check if push stream has space (like squeezelite checks outputbuf space)
                guard self.pushStream != 0 else {
                    os_log(.error, log: self.logger, "⚠️ No push stream available")
                    break
                }

                // Check TOTAL buffer: playback buffer + push queue
                // Like squeezelite checking _buf_space(outputbuf) before each decode
                let rawPB = BASS_ChannelGetData(self.pushStream, nil, DWORD(BASS_DATA_AVAILABLE))
                let rawQ = BASS_StreamPutData(self.pushStream, nil, 0)
                // BASS returns -1 (DWORD.max) on error (e.g. stream ended) — treat as 0
                let throttlePB = (rawPB == DWORD.max) ? 0 : Int(rawPB)
                let throttleQ = (rawQ == DWORD.max) ? 0 : Int(rawQ)

                // Throttle if total buffer is full (~10s of audio)
                if (throttlePB + throttleQ) > self.maxBufferSize {
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

                            if !self.wasManuallyStopped() {
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

                        // No-progress timeout: if 10s with no new audio decoded, stream is undecodable
                        if self.totalBytesPushed == bytesAtLoopStart && now.timeIntervalSince(loopStartTime) > 10.0 {
                            os_log(.error, log: self.logger, "❌ Decoder timeout: 10s with no audio decoded - stream may be undecodable")
                            if !self.wasManuallyStopped() {
                                DispatchQueue.main.async {
                                    self.delegate?.audioStreamDecoderDidEncounterError(self, error: -1)
                                }
                            }
                            break
                        }

                        Thread.sleep(forTimeInterval: 0.01)
                        continue
                    }

                    // Real error (not ENDED)
                    os_log(.error, log: self.logger, "❌ Decoder stream error: %d", error)

                    // On error, notify delegate
                    if !self.wasManuallyStopped() {
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

                        if !self.wasManuallyStopped() {
                            os_log(.info, log: self.logger, "🎵 Track decode COMPLETE (natural end) - notifying delegate")
                            DispatchQueue.main.async {
                                self.delegate?.audioStreamDecoderDidCompleteTrack(self)
                            }
                        } else {
                            os_log(.info, log: self.logger, "⏹️ Track decode stopped (manual skip)")
                        }
                        break
                    }

                    // No-progress timeout: if 10s with no new audio decoded, stream is undecodable
                    if self.totalBytesPushed == bytesAtLoopStart && Date().timeIntervalSince(loopStartTime) > 10.0 {
                        os_log(.error, log: self.logger, "❌ Decoder timeout: 10s with no audio decoded - stream may be undecodable")
                        if !self.wasManuallyStopped() {
                            DispatchQueue.main.async {
                                self.delegate?.audioStreamDecoderDidEncounterError(self, error: -1)
                            }
                        }
                        break
                    }

                    // Still connected - no data available yet, wait a bit (like squeezelite's usleep)
                    Thread.sleep(forTimeInterval: 0.001)
                    continue
                }

                // Push + write-position math is ONE critical section with the
                // control plane's flushBuffer/skipAhead: a chunk either lands
                // fully before a flush (and is cleared with the buffer) or is
                // dropped by the generation check — never half-counted
                // (bd LMS_StreamTest-433.2.2).
                self.stateLock.lock()

                guard self.isDecoding && generation == self.decodeGeneration else {
                    // Superseded after this chunk was decoded — drop it rather
                    // than pushing stale audio past a stop/flush.
                    self.stateLock.unlock()
                    break
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
                    self.stateLock.unlock()
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
                    self.stateLock.unlock()
                    let error = BASS_ErrorGetCode()
                    os_log(.error, log: self.logger, "❌ StreamPutData failed: %d", error)
                    break
                }

                // Count the chunk immediately — it IS in the push buffer now.
                // (The soft-throttle `continue` below used to skip this
                // increment, silently dropping throttled chunks from the
                // write-position math.)
                self.totalBytesPushed += UInt64(bytesRead)
                self.stateLock.unlock()

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

            // Clean up decoder stream — safe unconditionally: any newer start
            // is queued behind this block on the serial decodeQueue, so the
            // handle here is still this loop's own.
            if self.decoderStream != 0 {
                BASS_StreamFree(self.decoderStream)
                self.decoderStream = 0
            }
    }

    // MARK: - Stream Info Update

    /// currentStreamInfo is @Published (SwiftUI-observed) — assignments must
    /// happen on main. This path is reached from decodeQueue during track
    /// start (performStartDecoding), so marshal when off-main.
    private func setCurrentStreamInfoOnMain(_ info: AudioPlayer.StreamInfo?) {
        if Thread.isMainThread {
            audioPlayer?.currentStreamInfo = info
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.audioPlayer?.currentStreamInfo = info
            }
        }
    }

    /// Update stream info from decoder stream (shows actual format: FLAC, MP3, etc.)
    private func updateStreamInfoFromDecoder(_ stream: HSTREAM) {
        guard stream != 0 else {
            setCurrentStreamInfoOnMain(nil)
            return
        }

        // Get channel info from BASS decoder stream
        var info = BASS_CHANNELINFO()
        guard BASS_ChannelGetInfo(stream, &info) != 0 else {
            os_log(.error, log: logger, "❌ Failed to get decoder stream info: %d", BASS_ErrorGetCode())
            return
        }

        // Map ctype to human-readable format name
        let formatName = formatNameFromCType(info.ctype)

        // Extract bit depth from origres (LOWORD contains bits)
        let bitDepth = Int(info.origres & 0xFFFF)

        // bitrate comes from LMS metadata, not BASS — see StreamInfo.bitrateText.
        let streamInfo = AudioPlayer.StreamInfo(
            format: formatName,
            sampleRate: Int(info.freq),
            channels: Int(info.chans),
            bitDepth: bitDepth > 0 ? bitDepth : 16,  // Default to 16-bit if not specified
            bitrateText: audioPlayer?.carryOverBitrateText
        )

        setCurrentStreamInfoOnMain(streamInfo)
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
        if isWaitingForUnpause {
            os_log(.debug, log: logger, "🎯 Cleaning up synchronized start timer")
            stopSyncStartMonitoring()
            isWaitingForUnpause = false
            syncStartJiffies = nil
        }

        // Stop decoding (bumps the generation and clears isDecoding under lock)
        stopDecoding()

        // Cancel any pending sync-correction resume before freeing.
        // Generation counter inside cancelPendingResume defends against BASS handle
        // reuse if the freed DWORD is allocated to a new stream.
        cancelPendingResume()

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

    /// Mark current buffer position as track boundary for gapless transition
    private func markTrackBoundary() {
        // SQUEEZELITE-STYLE: Use totalBytesPushed as the boundary position.
        // This is our "writep" — the exact byte offset where Track B begins in the push stream.
        // BASS_SYNC_POS fires when BASS_ChannelGetPosition (our "readp") reaches this value.
        // Previous approach predicted boundary = playbackPos + playbackBuffer + queue,
        // which sampled 3 non-atomic BASS APIs and drifted ~42s with large queues.
        trackBoundaryPosition = totalBytesPushed

        let playbackPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
        let playbackBuffered = BASS_ChannelGetData(pushStream, nil, DWORD(BASS_DATA_AVAILABLE))
        let queuedAmount = Int(BASS_StreamPutData(pushStream, nil, 0))
        let totalBuffered = queuedAmount + Int(playbackBuffered)

        let bytesPerSec = sampleRate * channels * 4
        let boundarySeconds = Double(trackBoundaryPosition!) / Double(bytesPerSec)
        let playbackSeconds = Double(playbackPos) / Double(bytesPerSec)
        let oldPredicted = UInt64(playbackPos + UInt64(totalBuffered))

        os_log(.error, log: logger, "[BOUNDARY] 🎯 BOUNDARY = totalBytesPushed: %llu (%.2fs)", trackBoundaryPosition!, boundarySeconds)
        os_log(.error, log: logger, "[BOUNDARY] 📊 playbackPos: %llu (%.2fs), old predicted would be: %llu (delta: %lld bytes)",
               playbackPos, playbackSeconds, oldPredicted, Int64(oldPredicted) - Int64(trackBoundaryPosition!))
        os_log(.error, log: logger, "[BOUNDARY] 📊 buffer: pb=%dKB, queue=%dKB, total=%dKB (%.1fMB)",
               playbackBuffered / 1024, queuedAmount / 1024, totalBuffered / 1024, Double(totalBuffered) / 1_048_576)

        let bytesUntilBoundary = Int64(trackBoundaryPosition!) - Int64(playbackPos)
        let secondsUntilBoundary = Double(bytesUntilBoundary) / Double(bytesPerSec)
        os_log(.error, log: logger, "[BOUNDARY] 📊 ETA: %.2fs (%lld bytes ahead of playback)", secondsUntilBoundary, bytesUntilBoundary)

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

        // Apply pending ReplayGain now that playback has reached the new track
        // Like squeezelite's output.c:161: current_replay_gain = next_replay_gain
        if let pending = pendingReplayGain {
            os_log(.info, log: logger, "🎚️ ReplayGain boundary swap: %.4f → %.4f", currentReplayGain, pending)
            setReplayGain(pending)
            pendingReplayGain = nil
        }

        // Notify delegate of track transition - THIS SENDS STMs!
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📡 ABOUT TO SEND STMs - notifying delegate now...")
        delegate?.audioStreamDecoderDidReachTrackBoundary(self)
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] ✅ STMs SENT - new track should start playing now")

        // Clear boundary marker - now getCurrentPosition() will calculate
        // normally (under stateLock — the decode loop marks the NEXT track's
        // boundary under the same lock)
        stateLock.lock()
        trackBoundaryPosition = nil
        stateLock.unlock()

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
        if isWaitingForUnpause {
            os_log(.info, log: logger, "[APP-RECOVERY] 🔄 Clearing stale sync wait state for deferred track")
            isWaitingForUnpause = false
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
            cancelPendingResume()  // Stream identity changes; invalidate any pending resume.
            BASS_StreamFree(pushStream)
            pushStream = 0
        }

        os_log(.error, log: logger, "[APP-RECOVERY] 🔄 Initializing new push stream: %dHz, %dch", sampleRate, channels)
        initializePushStream(sampleRate: sampleRate, channels: channels)

        // Promote pending ReplayGain — fresh stream, no old audio to protect
        if let pending = pendingReplayGain {
            os_log(.info, log: logger, "🎚️ ReplayGain deferred→active for format-mismatch track: %.4f", pending)
            setReplayGain(pending)
            pendingReplayGain = nil
        }

        os_log(.error, log: logger, "[APP-RECOVERY] ▶️ Calling startPlayback() - should apply muting if muteNextStream=TRUE")
        startPlayback()

        // Mark as first track (new stream, starting fresh) and claim a fresh
        // generation for the deferred track's loop
        stateLock.lock()
        decodeGeneration += 1
        let generation = decodeGeneration
        trackStartPosition = 0
        previousTrackStartPosition = 0
        totalBytesPushed = 0
        lastBufferDiagnosticBytes = 0
        isDecoding = true
        manualStop = false
        stateLock.unlock()

        // Use the EXISTING decoder (already connected, at position 0:00!)
        // This preserves the HTTP connection so we get the track from the
        // beginning. Handle assignment + decode loop run on decodeQueue,
        // which owns the decoder stream (bd LMS_StreamTest-433.2.2).
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            self.decoderStream = track.decoderStream
            self.runDecoderLoop(generation: generation)
        }

        // Update stream info NOW (deferred track is actually starting)
        updateStreamInfoFromDecoder(track.decoderStream)

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

        // Snapshot the boundary fields under stateLock — the decode loop
        // updates them mid-gapless under the same lock; a torn read here
        // would feed garbage to MPNowPlayingInfoCenter.
        stateLock.lock()
        let boundary = trackBoundaryPosition
        let trackStart = trackStartPosition
        let previousStart = previousTrackStartPosition
        stateLock.unlock()

        // CRITICAL: For gapless, keep reporting OLD track's position until boundary crossed
        // When new track is queued, trackStartPosition is updated to the boundary position
        // But we shouldn't report "new track at 0 seconds" until playback actually reaches that boundary!
        // Instead, continue reporting position from the PREVIOUS track's start position
        if let boundaryPos = boundary, playbackBytes < boundaryPos {
            // Still playing old track - calculate position from PREVIOUS track start
            // previousTrackStartPosition is saved before trackStartPosition gets updated to boundary

            // Protect against underflow
            guard playbackBytes >= previousStart else {
                os_log(.error, log: logger, "⚠️ Before boundary: playback (%llu) < previous start (%llu) - returning 0", playbackBytes, previousStart)
                return 0
            }

            let trackBytes = playbackBytes - previousStart
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
        guard playbackBytes >= trackStart else {
            os_log(.error, log: logger, "⚠️ Playback position (%llu) < track start (%llu) - returning 0", playbackBytes, trackStart)
            return 0
        }

        let trackBytes = playbackBytes - trackStart

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

    /// Player-state string for the push stream, mirroring the values
    /// AudioPlayer.getPlayerState() returns so AudioManager can report a
    /// single vocabulary regardless of which pipeline is active.
    func getPlayerState() -> String {
        guard pushStream != 0 else { return "No Stream" }
        switch BASS_ChannelIsActive(pushStream) {
        case DWORD(BASS_ACTIVE_STOPPED): return "Stopped"
        case DWORD(BASS_ACTIVE_PLAYING): return "Playing"
        case DWORD(BASS_ACTIVE_PAUSED): return "Paused"
        case DWORD(BASS_ACTIVE_STALLED): return "Buffering"
        default: return "Unknown"
        }
    }

    /// Check if we have a valid push stream (playing OR paused)
    func hasValidStream() -> Bool {
        guard pushStream != 0 else { return false }
        let state = BASS_ChannelIsActive(pushStream)
        // PLAYING / PAUSED: actively in use.
        // STOPPED + waiting for sync: fresh stream created via 's' command, queued for
        //   synchronized start by the upcoming 'u'. Without this case, the 'u' command's
        //   hasActiveStream check sees "STOPPED" and incorrectly routes to playlist-jump
        //   recovery instead of letting the sync timer fire.
        return state == DWORD(BASS_ACTIVE_PLAYING)
            || state == DWORD(BASS_ACTIVE_PAUSED)
            || (state == DWORD(BASS_ACTIVE_STOPPED) && isWaitingForUnpause)
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

    /// Called immediately after a push stream is created or recreated.
    /// Used by SyncController to clear drift residual and reset rate offset to nominal —
    /// any prior offset is meaningless on a fresh stream.
    func audioStreamDecoderDidRecreatePushStream(_ decoder: AudioStreamDecoder)

    /// Called immediately after a successful BASS_ChannelPlay on the push stream.
    /// Mirrors squeezelite's `output.track_started` — the precise moment audio
    /// production transitions from 0 to >0. The coordinator uses this to send
    /// STMs at the right moment (and only if BASS actually plays — guards
    /// against the false-STMs case if BASS_ChannelPlay fails).
    func audioStreamDecoderDidStartPlayback(_ decoder: AudioStreamDecoder)
}

/// Track metadata for boundary updates
struct TrackMetadata {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}
