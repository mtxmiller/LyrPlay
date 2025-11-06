// File: AudioStreamDecoder.swift
// Buffer-level gapless playback implementation using BASS push streams
// Based on squeezelite's proven architecture
import Foundation
import os.log

// MARK: - Global BASS Callbacks

/// Global callback for buffer stall events
private func bassStallCallback(handle: HSYNC, channel: DWORD, data: DWORD, user: UnsafeMutableRawPointer?) {
    if data == 0 {
        os_log(.error, "⚠️ BUFFER STALLED - playback interrupted!")
    } else {
        os_log(.info, "✅ Buffer resumed after stall")
    }
}

/// Global callback for track boundary sync
private func bassTrackBoundaryCallback(handle: HSYNC, channel: DWORD, data: DWORD, user: UnsafeMutableRawPointer?) {
    guard let user = user else { return }
    let decoder = Unmanaged<AudioStreamDecoder>.fromOpaque(user).takeUnretainedValue()

    DispatchQueue.main.async {
        decoder.handleTrackBoundary()
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

    /// Track boundary position in buffer (for gapless transitions)
    private var trackBoundaryPosition: UInt64?

    /// Flag to mark boundary on next decoded chunk (like squeezelite's decode.new_stream)
    /// Set when new STRM arrives, cleared when first chunk of new track is written
    /// This ensures boundary is marked AFTER old decoder finishes pushing buffered audio
    private var pendingTrackBoundary: Bool = false

    /// Metadata for next track (applied at boundary)
    private var nextTrackMetadata: TrackMetadata?

    /// Current track start position (for accurate position tracking)
    private var trackStartPosition: UInt64 = 0

    /// Previous track start position (for reporting position before boundary crossed)
    /// When queueing gapless track, trackStartPosition gets updated to boundary
    /// But we need to keep reporting old track's position until boundary is reached
    private var previousTrackStartPosition: UInt64 = 0

    /// Maximum buffer size before throttling (in bytes)
    /// Default: ~4 seconds @ 44.1kHz stereo float = 44100 * 2 * 4 * 4 = 705,600 bytes
    private let maxBufferSize: Int = 705_600

    // MARK: - Silent Recovery Support
    /// Flag to mute the next stream creation (for silent app foreground recovery)
    /// When true, DSP gain is set to 0.001 immediately upon push stream playback start
    var muteNextStream: Bool = false

    /// Registered sync handles (for cleanup)
    private var trackBoundarySyncs: [HSYNC] = []

    // MARK: - Delegate

    weak var delegate: AudioStreamDecoderDelegate?

    // MARK: - Initialization

    init() {
        decodeQueue = DispatchQueue(label: "com.lyrplay.decoder", qos: .userInitiated)
        os_log(.info, log: logger, "✅ AudioStreamDecoder initialized")
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

        // Set up buffer stall detection
        setupSyncCallbacks()

        os_log(.info, log: logger, "✅ Push stream created: handle=%d", pushStream)
    }

    /// Set up BASS sync callbacks for monitoring
    private func setupSyncCallbacks() {
        // Buffer stall monitoring
        let stallSync = BASS_ChannelSetSync(
            pushStream,
            DWORD(BASS_SYNC_STALL),
            0,
            bassStallCallback,
            nil
        )

        trackBoundarySyncs.append(stallSync)

        os_log(.info, log: logger, "✅ Sync callbacks registered")
    }

    /// Start BASS playback of push stream
    func startPlayback() -> Bool {
        guard pushStream != 0 else {
            os_log(.error, log: logger, "❌ Cannot start playback - no push stream")
            return false
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
        guard pushStream != 0 else { return }
        BASS_ChannelPlay(pushStream, 0)
        os_log(.info, log: logger, "▶️ Push stream resumed")
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

    // MARK: - Decoder Stream Management

    /// Start decoding from HTTP URL (like squeezelite's decoder thread)
    /// - Parameters:
    ///   - url: HTTP URL to decode from
    ///   - format: Audio format (flc, mp3, ops, etc.)
    ///   - isNewTrack: Whether this is a new track (for gapless boundary marking)
    func startDecodingFromURL(_ url: String, format: String, isNewTrack: Bool = false) {
        os_log(.info, log: logger, "🎵 Starting decoder for %{public}s: %{public}s", format, url)

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

        // If sample rate doesn't match, we need to recreate push stream
        if actualSampleRate != sampleRate || actualChannels != channels {
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

        // CRITICAL: Must stop stream before flushing buffer
        BASS_ChannelStop(pushStream)
        os_log(.info, log: logger, "⏸️ Stopped stream for buffer flush")

        // Method 1: Set position to 0 to reset stream (per BASS docs)
        // This resets both buffer contents AND position counter
        BASS_ChannelSetPosition(pushStream, 0, DWORD(BASS_POS_BYTE))

        // Method 2: Restart to clear the buffer
        // BASS_ChannelPlay with restart=TRUE clears buffer contents
        let result = BASS_ChannelPlay(pushStream, 1)  // 1 = restart (clears buffer)
        if result != 0 {
            // Verify position was reset
            let newPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
            os_log(.info, log: logger, "📊 BASS position AFTER flush: %llu (should be 0)", newPos)

            trackStartPosition = 0  // Reset track start for position calculation
            previousTrackStartPosition = 0
            totalBytesPushed = 0  // Reset write position
            os_log(.info, log: logger, "✅ Buffer flushed and stream restarted")
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
                        os_log(.debug, log: self.logger, "⏳ Decoder buffer empty (HTTP still active), waiting...")
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

                // Track total bytes for position calculation
                self.totalBytesPushed += UInt64(bytesRead)
            }

            os_log(.info, log: self.logger, "🛑 Decoder loop stopped")

            // Clean up decoder stream
            if self.decoderStream != 0 {
                BASS_StreamFree(self.decoderStream)
                self.decoderStream = 0
            }
        }
    }

    /// Stop and cleanup push stream
    func cleanup() {
        os_log(.info, log: logger, "🧹 Cleaning up push stream")

        // Stop decoding
        isDecoding = false
        stopDecoding()

        // Remove all syncs
        for sync in trackBoundarySyncs {
            BASS_ChannelRemoveSync(pushStream, sync)
        }
        trackBoundarySyncs.removeAll()

        // Free stream
        if pushStream != 0 {
            BASS_StreamFree(pushStream)
            pushStream = 0
        }

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
        // CRITICAL: Like squeezelite output.track_start = outputbuf->writep
        // The boundary is at the WRITE position (where we've written to),
        // NOT the playback position (where we're reading from)!
        // totalBytesPushed tracks our write position (like squeezelite's writep)
        trackBoundaryPosition = totalBytesPushed

        let boundarySeconds = Double(trackBoundaryPosition!) / Double(sampleRate * channels * 4)
        os_log(.error, log: logger, "🎯🎯🎯 TRACK BOUNDARY MARKED at WRITE position: %llu bytes (%.2f seconds)", trackBoundaryPosition!, boundarySeconds)

        // Get current playback position for comparison
        let playbackPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
        let playbackSeconds = Double(playbackPos) / Double(sampleRate * channels * 4)
        os_log(.error, log: logger, "📊 Current playback position: %llu bytes (%.2f seconds)", playbackPos, playbackSeconds)

        // Calculate how long until boundary is reached
        let bytesUntilBoundary = Int64(trackBoundaryPosition!) - Int64(playbackPos)
        let secondsUntilBoundary = Double(bytesUntilBoundary) / Double(sampleRate * channels * 4)
        os_log(.error, log: logger, "📊 Playback will reach boundary in %.2f seconds (%lld bytes ahead)", secondsUntilBoundary, bytesUntilBoundary)

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
            os_log(.error, log: logger, "✅ BASS sync callback registered for boundary position: %llu", trackBoundaryPosition!)
        } else {
            let error = BASS_ErrorGetCode()
            os_log(.error, log: logger, "❌ Failed to set boundary sync! BASS error: %d", error)
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

        os_log(.error, log: logger, "🎯🎯🎯 TRACK BOUNDARY REACHED - playback entered new track audio")
        os_log(.error, log: logger, "📊 Playback position: %llu bytes (%.2f seconds)", playbackPos, playbackSeconds)

        if let boundaryPos = trackBoundaryPosition {
            let boundarySeconds = Double(boundaryPos) / Double(sampleRate * channels * 4)
            os_log(.error, log: logger, "📊 Expected boundary: %llu bytes (%.2f seconds)", boundaryPos, boundarySeconds)

            // Log the difference (should be very close)
            let diff = Int64(playbackPos) - Int64(boundaryPos)
            os_log(.error, log: logger, "📊 Timing accuracy: %lld bytes difference", diff)
        }

        os_log(.error, log: logger, "📊 Write position (totalBytesPushed): %llu bytes", totalBytesPushed)
        let writeReadGap = Int64(totalBytesPushed) - Int64(playbackPos)
        os_log(.error, log: logger, "📊 Write-Read gap: %lld bytes (buffer ahead of playback)", writeReadGap)

        // CRITICAL: Remove all OLD boundary syncs that have now fired
        // Only keep syncs for future boundaries (prevents stale callbacks)
        // Note: BASS_ChannelRemoveSync is safe to call even if sync already auto-removed
        let syncCount = trackBoundarySyncs.count
        for sync in trackBoundarySyncs {
            BASS_ChannelRemoveSync(pushStream, sync)
        }
        trackBoundarySyncs.removeAll()
        os_log(.info, log: logger, "🧹 Cleared %d old boundary sync(s)", syncCount)

        // trackStartPosition is already set to boundary position in startDecodingFromURL()
        // Don't update it here - it's already correct!
        // The boundary position IS the track start position

        // Notify delegate of track transition
        delegate?.audioStreamDecoderDidReachTrackBoundary(self)

        // Clear boundary marker - now getCurrentPosition() will calculate normally
        trackBoundaryPosition = nil

        os_log(.error, log: logger, "✅ Boundary handling complete - STMs should be sent NOW")
    }

    // MARK: - Position Tracking

    /// Get current playback position within current track
    /// Returns PLAYBACK position (not decode position) - what's actually been played
    /// This matches squeezelite reporting frames_played (not frames_decoded)
    /// Position is relative to trackStartPosition (like squeezelite's output.track_start)
    func getCurrentPosition() -> TimeInterval {
        guard pushStream != 0 else { return 0 }

        // Get PLAYBACK position from BASS (not decode position!)
        // BASS_POS_BYTE gives playback position (what's actually played)
        // BASS_POS_DECODE would give decode position (ahead due to buffering)
        let playbackBytes = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))

        os_log(.info, log: logger, "📊 POS: BASS playback=%llu trackStart=%llu prevStart=%llu boundary=%{public}s",
               playbackBytes, trackStartPosition, previousTrackStartPosition,
               trackBoundaryPosition.map { String($0) } ?? "none")

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
            os_log(.info, log: logger, "⏳ Before boundary (at %llu, boundary at %llu) - reporting old track position: %.2f", playbackBytes, boundaryPos, seconds)
            os_log(.info, log: logger, "📊 RETURNING POSITION: %.2f seconds (before boundary mode)", seconds)
            return max(0, seconds)
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

        os_log(.info, log: logger, "📊 RETURNING POSITION: %.2f seconds (after boundary / normal mode, trackBytes=%llu)", seconds, trackBytes)
        return max(0, seconds)  // Ensure non-negative
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
        os_log(.info, log: logger, "AudioStreamDecoder deinitialized")
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
