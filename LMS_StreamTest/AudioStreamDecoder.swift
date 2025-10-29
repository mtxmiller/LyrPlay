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

    /// Track boundary position in buffer (for gapless transitions)
    private var trackBoundaryPosition: UInt64?

    /// Metadata for next track (applied at boundary)
    private var nextTrackMetadata: TrackMetadata?

    /// Current track start position (for accurate position tracking)
    private var trackStartPosition: UInt64 = 0

    /// Maximum buffer size before throttling (in bytes)
    /// Default: ~4 seconds @ 44.1kHz stereo float = 44100 * 2 * 4 * 4 = 705,600 bytes
    private let maxBufferSize: Int = 705_600

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
            os_log(.info, log: logger, "▶️ Push stream playback started")
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

    /// Stop and cleanup push stream
    func cleanup() {
        os_log(.info, log: logger, "🧹 Cleaning up push stream")

        // Stop decoding
        isDecoding = false

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
        // Get current playback position
        let currentPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))

        // Get amount of buffered data
        let bufferedBytes = BASS_ChannelGetData(pushStream, nil, DWORD(BASS_DATA_AVAILABLE))

        // Boundary is at end of current buffer
        trackBoundaryPosition = currentPos + UInt64(bufferedBytes)

        os_log(.info, log: logger, "🎯 Track boundary marked at position: %llu", trackBoundaryPosition!)

        // Set sync callback for this boundary
        let sync = BASS_ChannelSetSync(
            pushStream,
            DWORD(BASS_SYNC_POS | BASS_SYNC_MIXTIME),
            trackBoundaryPosition!,
            bassTrackBoundaryCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        trackBoundarySyncs.append(sync)
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
        os_log(.info, log: logger, "🎯 Track boundary reached - updating metadata")

        // Reset position counter for new track
        trackStartPosition = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))

        // Notify delegate of track transition
        delegate?.audioStreamDecoderDidReachTrackBoundary(self)

        // Clear boundary marker
        trackBoundaryPosition = nil
    }

    // MARK: - Position Tracking

    /// Get current playback position within current track
    func getCurrentPosition() -> TimeInterval {
        guard pushStream != 0 else { return 0 }

        let currentPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
        let bytesIntoTrack = currentPos - trackStartPosition

        // Convert bytes to seconds
        let bytesPerSecond = sampleRate * channels * 4  // 4 bytes per float sample
        let seconds = Double(bytesIntoTrack) / Double(bytesPerSecond)

        return seconds
    }

    /// Check if stream is currently playing
    func isPlaying() -> Bool {
        guard pushStream != 0 else { return false }
        return BASS_ChannelIsActive(pushStream) == DWORD(BASS_ACTIVE_PLAYING)
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
