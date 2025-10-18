# LyrPlay Gapless Playback Migration Plan

## Executive Summary

This document outlines a **phased, non-breaking migration** from the current URL-based streaming to a hybrid architecture that supports both:
1. **Buffer-level gapless** (for SlimProto direct streams)
2. **URL-based streaming** (for HTTP streams, radio, external URLs)

## Current Architecture Analysis

### What We Have Now (✅ Working)

```
SlimProto STRM → Extract HTTP URL → BASS_StreamCreateURL() → Pull Stream → Output
```

**Capabilities**:
- ✅ FLAC, MP3, AAC, Opus, OGG playback
- ✅ HTTP streaming (radio stations, external URLs)
- ✅ Seek support
- ✅ ReplayGain
- ✅ Lock screen controls
- ✅ Now Playing metadata
- ✅ Phone call interruption handling
- ✅ Route change handling (AirPods, CarPlay)
- ✅ Server time synchronization
- ✅ Track end detection
- ❌ **Gapless transitions** (gaps during track changes)

### What Must Be Preserved (Requirements)

1. **All existing playback functionality**
2. **HTTP streaming capability** (for radio, external URLs)
3. **Backward compatibility** (app must work during migration)
4. **No user-facing breakage** (incremental deployment)
5. **Easy rollback** (feature flags for new code paths)

## Hybrid Architecture Design

### Two Playback Modes

```
┌─────────────────────────────────────────────────────────┐
│                    AudioPlayer                           │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Mode 1: PUSH STREAM (Gapless)                          │
│  ┌────────────────────────────────────────┐             │
│  │ SlimProto Socket → Decoder → PutData  │             │
│  │         ↓                              │             │
│  │  BASS Push Stream (SINGLE INSTANCE)   │             │
│  │         ↓                              │             │
│  │  Track Boundary Syncs (gapless)       │             │
│  └────────────────────────────────────────┘             │
│                                                          │
│  Mode 2: URL STREAM (Legacy - for HTTP/Radio)           │
│  ┌────────────────────────────────────────┐             │
│  │ HTTP URL → BASS_StreamCreateURL()     │             │
│  │         ↓                              │             │
│  │  BASS Pull Stream (per track)         │             │
│  │         ↓                              │             │
│  │  Traditional end detection            │             │
│  └────────────────────────────────────────┘             │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Decision Logic

```swift
func playStream(url: String, format: String, mode: StreamMode) {
    switch mode {
    case .direct:
        // Use push stream for gapless
        streamDecoder.setupPushStream(format: format)
        streamDecoder.startDecodingFromSocket()

    case .http:
        // Use URL stream for HTTP/radio
        createURLStream(url: url, format: format)
    }
}

enum StreamMode {
    case direct   // SlimProto direct stream (autostart='0')
    case http     // HTTP URL stream (autostart='3')
}
```

## Migration Phases

### Phase 1: Foundation (Week 1-2)
**Goal**: Create infrastructure without breaking existing functionality

#### 1.1 Create AudioStreamDecoder Class
```swift
// New file: AudioStreamDecoder.swift
class AudioStreamDecoder {
    private var pushStream: HSTREAM = 0
    private var isUsingPushStream: Bool = false

    // Decode queue for async processing
    private let decodeQueue: DispatchQueue

    // Track boundary tracking
    private var trackBoundaryPosition: UInt64?
    private var trackBoundarySyncs: [HSYNC] = []

    init() {
        decodeQueue = DispatchQueue(label: "com.lyrplay.decoder",
                                     qos: .userInitiated)
    }

    // Stub methods - implementation in Phase 2
    func setupPushStream(format: String, sampleRate: Int, channels: Int) {
        // TODO: Create BASS push stream
    }

    func pushDecodedData(_ data: Data, isNewTrack: Bool) {
        // TODO: Call BASS_StreamPutData()
    }

    func getBufferLevel() -> Int {
        // TODO: Call BASS_ChannelGetData(BASS_DATA_AVAILABLE)
        return 0
    }
}
```

**Testing**:
- ✅ Class compiles
- ✅ Can be instantiated
- ✅ No impact on existing playback

---

#### 1.2 Add Feature Flag System
```swift
// In SettingsManager.swift
class SettingsManager {
    // Feature flags for gradual rollout
    @Published var enableGaplessPlayback: Bool = false  // Default OFF
    @Published var enableDirectStreamMode: Bool = false // Default OFF

    // Debug settings
    @Published var logDecoderStats: Bool = false
}
```

**Testing**:
- ✅ Settings persist
- ✅ UI can toggle flags
- ✅ Flags readable from AudioPlayer

---

#### 1.3 Modify AudioPlayer for Dual Mode
```swift
// In AudioPlayer.swift
class AudioPlayer {
    // NEW: Add decoder reference
    private let streamDecoder = AudioStreamDecoder()

    // NEW: Track current mode
    private var currentMode: StreamMode = .http  // Default to legacy

    // EXISTING CODE UNCHANGED - all current methods work as-is

    // NEW: Mode selection method
    private func selectStreamMode(autostart: String) -> StreamMode {
        // Feature flag check
        guard settings.enableDirectStreamMode else {
            return .http  // Force legacy mode if flag OFF
        }

        // Autostart detection
        switch autostart {
        case "0":  // Direct stream
            return .direct
        case "3":  // HTTP URL
            return .http
        default:
            return .http  // Safe fallback
        }
    }
}
```

**Testing**:
- ✅ Existing playback still works (mode = .http)
- ✅ Feature flag controls behavior
- ✅ No regressions

---

### Phase 2: Push Stream Infrastructure (Week 3-4)
**Goal**: Implement push stream without using it for playback yet

#### 2.1 Implement BASS Push Stream Creation
```swift
// In AudioStreamDecoder.swift
func setupPushStream(format: String, sampleRate: Int = 44100, channels: Int = 2) {
    os_log(.info, log: logger, "🎵 Creating push stream: %{public}s @ %dHz",
           format, sampleRate)

    // Create push stream
    pushStream = BASS_StreamCreate(
        UInt32(sampleRate),
        UInt32(channels),
        BASS_SAMPLE_FLOAT,      // Use float samples like squeezelite
        STREAMPROC_PUSH.rawValue,
        nil
    )

    guard pushStream != 0 else {
        let error = BASS_ErrorGetCode()
        os_log(.error, log: logger, "❌ Push stream creation failed: %d", error)
        return
    }

    setupSyncs()
    isUsingPushStream = true

    os_log(.info, log: logger, "✅ Push stream created: handle=%d", pushStream)
}

private func setupSyncs() {
    // Buffer stall monitoring
    let stallSync = BASS_ChannelSetSync(pushStream,
        BASS_SYNC_STALL,
        0,
        stallCallback,
        nil)

    trackBoundarySyncs.append(stallSync)
}

private let stallCallback: SYNCPROC = { handle, channel, data, user in
    if data == 0 {
        os_log(.warning, "⚠️ Buffer stalled!")
    } else {
        os_log(.info, "✅ Buffer resumed")
    }
}
```

**Testing**:
- ✅ Push stream creates successfully
- ✅ Syncs register
- ✅ Can query buffer level
- ❌ NOT used for playback yet

---

#### 2.2 Implement Buffer Monitoring
```swift
func getBufferLevel() -> Int {
    guard pushStream != 0 else { return 0 }
    return Int(BASS_ChannelGetData(pushStream, nil, BASS_DATA_AVAILABLE))
}

func getBufferStats() -> (buffered: Int, playing: Int, queued: Int) {
    let buffered = getBufferLevel()
    let position = BASS_ChannelGetPosition(pushStream, BASS_POS_BYTE)
    let queued = buffered  // For push streams, queued = buffered

    return (buffered: buffered,
            playing: Int(position),
            queued: queued)
}
```

**Testing**:
- ✅ Can monitor buffer levels
- ✅ Stats logging works
- ✅ No crashes

---

### Phase 3: Format Decoders (Week 5-6)
**Goal**: Add decoders for each format, test with test files

#### 3.1 FLAC Decoder Integration
```swift
// Use BassFLAC for decoding
func decodeFLACChunk(_ compressedData: Data) -> Data? {
    // Option 1: Use BASS_FLAC_StreamCreateFile with memory
    // Option 2: Use external FLAC decoder library

    // For now, we can use BASS itself to decode
    // Create a decode-only stream, read samples, feed to push stream

    let tempStream = BASS_FLAC_StreamCreateFile(
        BOOL(0),  // memory = false
        data.bytes,
        0,  // offset
        UInt64(data.count),  // length
        BASS_STREAM_DECODE  // Decode only, don't play
    )

    // Read decoded samples
    var buffer = [Float](repeating: 0, count: 4096)
    let bytesRead = BASS_ChannelGetData(tempStream, &buffer, UInt32(buffer.count * 4))

    BASS_StreamFree(tempStream)

    return Data(bytes: buffer, count: Int(bytesRead))
}
```

**Testing**:
- ✅ Can decode FLAC chunks
- ✅ PCM data is valid
- ✅ No format errors

---

#### 3.2 MP3/AAC Decoder
```swift
func decodeCompressedChunk(_ compressedData: Data, format: String) -> Data? {
    // Similar approach using BASS decoders
    // MP3: Built into BASS
    // AAC: Built into BASS on iOS

    // Create temporary decode stream from memory
    let tempStream = BASS_StreamCreateFile(
        BOOL(1),  // memory = true
        compressedData.bytes,
        0,
        UInt64(compressedData.count),
        BASS_STREAM_DECODE
    )

    // Read and return PCM
    // ... similar to FLAC
}
```

**Testing**:
- ✅ MP3 decoding works
- ✅ AAC decoding works
- ✅ Output matches expected format

---

### Phase 4: SlimProto Integration (Week 7-8)
**Goal**: Connect decoders to SlimProto socket, still not playing

#### 4.1 Socket Data Reading
```swift
// In AudioStreamDecoder.swift
func startDecodingFromSocket(_ socket: GCDAsyncSocket, format: String) {
    isDecoding = true

    decodeQueue.async {
        while self.isDecoding {
            // Read chunk from socket
            guard let chunk = self.readChunkFromSocket(socket) else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            // Decode based on format
            guard let pcmData = self.decodeChunk(chunk, format: format) else {
                os_log(.error, "Failed to decode chunk")
                continue
            }

            // Push to BASS buffer
            self.pushDecodedData(pcmData, isNewTrack: false)

            // Monitor buffer - throttle if too full
            let buffered = self.getBufferLevel()
            if buffered > self.maxBufferSize {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}

private func readChunkFromSocket(_ socket: GCDAsyncSocket) -> Data? {
    // Read from SlimProto socket
    // This needs coordination with SlimProtoClient
    // For now, stub it
    return nil
}
```

**Testing**:
- ✅ Can read from socket
- ✅ Decoding loop runs
- ✅ Buffer fills correctly
- ❌ Still not playing

---

#### 4.2 Modify SlimProtoCommandHandler
```swift
// In SlimProtoCommandHandler.swift
private func handleStartCommand(url: String, format: String, startTime: Double,
                                replayGain: Float, autostart: String) {

    let mode = selectStreamMode(autostart: autostart)

    switch mode {
    case .direct:
        os_log(.info, "🎵 Using DIRECT stream mode (gapless)")
        delegate?.didStartDirectStream(format: format,
                                      startTime: startTime,
                                      replayGain: replayGain)

    case .http:
        os_log(.info, "🎵 Using HTTP stream mode (legacy)")
        delegate?.didStartStream(url: url,
                                format: format,
                                startTime: startTime,
                                replayGain: replayGain)
    }
}

private func selectStreamMode(autostart: String) -> StreamMode {
    guard SettingsManager.shared.enableDirectStreamMode else {
        return .http
    }

    return autostart == "0" ? .direct : .http
}
```

**Testing**:
- ✅ Routing logic works
- ✅ Feature flag controls path
- ✅ Existing HTTP streams unaffected

---

### Phase 5: Playback Integration (Week 9-10)
**Goal**: Actually play audio through push stream

#### 5.1 Enable Push Stream Playback
```swift
// In AudioPlayer.swift
func playDirectStream(format: String, startTime: Double, replayGain: Float) {
    os_log(.info, "▶️ Playing direct stream: %{public}s", format)

    // Setup decoder
    streamDecoder.setupPushStream(format: format)

    // Start BASS playback
    let result = BASS_ChannelPlay(streamDecoder.pushStream, 0)
    guard result != 0 else {
        let error = BASS_ErrorGetCode()
        os_log(.error, "❌ Push stream play failed: %d", error)
        return
    }

    // Apply replay gain
    applyReplayGainToPushStream(replayGain)

    // Start decoding from socket
    if let socket = getSlimProtoSocket() {
        streamDecoder.startDecodingFromSocket(socket, format: format)
    }

    os_log(.info, "✅ Direct stream playback started")
}
```

**Testing**:
- ✅ Audio plays
- ✅ Quality is good
- ✅ Buffer doesn't starve
- ✅ Can pause/resume
- ❌ Track transitions still have gaps

---

### Phase 6: Gapless Transitions (Week 11-12)
**Goal**: Implement sample-perfect track changes

#### 6.1 Track Boundary Markers
```swift
// In AudioStreamDecoder.swift
func markNextTrackBoundary(metadata: TrackMetadata) {
    guard pushStream != 0 else { return }

    // Get current buffer position
    let currentPos = BASS_ChannelGetPosition(pushStream, BASS_POS_BYTE)
    let bufferedBytes = UInt64(BASS_ChannelGetData(pushStream, nil, BASS_DATA_AVAILABLE))

    // Mark boundary at end of current buffer
    trackBoundaryPosition = currentPos + bufferedBytes
    nextTrackMetadata = metadata

    os_log(.info, "🎯 Track boundary marked at position: %llu", trackBoundaryPosition!)

    // Set sync for boundary
    let sync = BASS_ChannelSetSync(pushStream,
        BASS_SYNC_POS | BASS_SYNC_MIXTIME,
        trackBoundaryPosition!,
        trackBoundaryCallback,
        Unmanaged.passUnretained(self).toOpaque())

    trackBoundarySyncs.append(sync)
}

private let trackBoundaryCallback: SYNCPROC = { handle, channel, data, user in
    guard let user = user else { return }
    let decoder = Unmanaged<AudioStreamDecoder>.fromOpaque(user).takeUnretainedValue()

    DispatchQueue.main.async {
        decoder.handleTrackBoundary()
    }
}

private func handleTrackBoundary() {
    os_log(.info, "🎯 Track boundary reached - updating metadata")

    // Update Now Playing
    if let metadata = nextTrackMetadata {
        NowPlayingManager.shared.updateTrackInfo(
            title: metadata.title,
            artist: metadata.artist,
            duration: metadata.duration
        )
    }

    // Reset position counter for new track
    trackStartPosition = BASS_ChannelGetPosition(pushStream, BASS_POS_BYTE)

    // Clear boundary marker
    trackBoundaryPosition = nil
    nextTrackMetadata = nil

    // Notify delegate
    delegate?.didTransitionToNextTrack()
}
```

**Testing**:
- ✅ Boundaries detected
- ✅ Metadata updates at right time
- ✅ No audio gaps
- ✅ Position resets correctly

---

#### 6.2 Handle STRM Command for Gapless
```swift
// In SlimProtoCommandHandler.swift
case UInt8(ascii: "s"): // start - check if it's a new track in same stream
    if isUsingDirectStream && audioIsPlaying {
        // Gapless transition - mark boundary
        os_log(.info, "🎯 Gapless transition detected")
        delegate?.didReceiveNextTrack(url: url,
                                     format: formatName,
                                     replayGain: replayGainFloat,
                                     metadata: extractMetadata(from: url))
    } else {
        // First track or after stop
        handleStartCommand(url: url,
                          format: formatName,
                          startTime: 0.0,
                          replayGain: replayGainFloat,
                          autostart: String(autostart))
    }
```

**Testing**:
- ✅ Track 1 → Track 2 is gapless
- ✅ Track 2 → Track 3 is gapless
- ✅ Metadata updates correctly
- ✅ Position tracking works

---

### Phase 7: Polish & Edge Cases (Week 13-14)
**Goal**: Handle all edge cases

#### 7.1 Sample Rate Changes
```swift
func handleSampleRateChange(newRate: Int) {
    os_log(.info, "🔄 Sample rate changing: %d → %d", currentSampleRate, newRate)

    // Like squeezelite: pause briefly, reconfigure, resume
    let wasPlaying = BASS_ChannelIsActive(pushStream) == BASS_ACTIVE_PLAYING

    if wasPlaying {
        BASS_ChannelPause(pushStream)
    }

    // Reconfigure BASS output
    BASS_SetConfig(BASS_CONFIG_UPDATEPERIOD, UInt32(newRate / 100))

    // Resume
    if wasPlaying {
        BASS_ChannelPlay(pushStream, 0)
    }

    currentSampleRate = newRate
}
```

**Testing**:
- ✅ 44.1kHz → 48kHz transition works
- ✅ 48kHz → 96kHz transition works
- ✅ No clicks or pops

---

#### 7.2 Buffer Starvation Recovery
```swift
func handleBufferStarvation() {
    os_log(.warning, "⚠️ Buffer starvation - increasing decode priority")

    // Boost decode queue priority
    decodeQueue.async(qos: .userInteractive) {
        // Decode more aggressively
        self.decodeMultipleChunks(count: 5)
    }

    // Notify UI
    delegate?.didStall()
}
```

**Testing**:
- ✅ Recovers from starvation
- ✅ Doesn't over-buffer
- ✅ Smooth resume

---

### Phase 8: Production Rollout (Week 15-16)

#### 8.1 Beta Testing
- Enable feature flag for internal testing
- Test on multiple devices (iPhone, iPad)
- Test on different iOS versions
- Test different network conditions

#### 8.2 Gradual Rollout
```swift
// Week 1: 10% of users
let rolloutPercentage = 0.10

// Week 2: 25% of users
let rolloutPercentage = 0.25

// Week 3: 50% of users
let rolloutPercentage = 0.50

// Week 4: 100% of users
let rolloutPercentage = 1.0
```

#### 8.3 Monitoring
- Log buffer stats
- Track transition success rate
- Monitor crashes related to decoder
- Collect user feedback

---

## Rollback Strategy

### Immediate Rollback (Emergency)
```swift
// Disable feature flag via remote config or app update
SettingsManager.shared.enableDirectStreamMode = false

// All users immediately revert to HTTP streaming
```

### Partial Rollback
```swift
// Keep feature enabled for some formats
func shouldUseDirectStream(format: String) -> Bool {
    guard settings.enableDirectStreamMode else { return false }

    // Only use for FLAC initially
    switch format {
    case "FLAC":
        return true
    default:
        return false  // Fall back to HTTP for other formats
    }
}
```

---

## Testing Strategy

### Unit Tests
```swift
class AudioStreamDecoderTests: XCTestCase {
    func testPushStreamCreation() {
        let decoder = AudioStreamDecoder()
        decoder.setupPushStream(format: "FLAC", sampleRate: 44100, channels: 2)

        XCTAssertNotEqual(decoder.pushStream, 0)
        XCTAssertTrue(decoder.isUsingPushStream)
    }

    func testBufferMonitoring() {
        // ...
    }

    func testTrackBoundaryDetection() {
        // ...
    }
}
```

### Integration Tests
```swift
class GaplessPlaybackTests: XCTestCase {
    func testTwoTrackGaplessTransition() {
        // Play track 1
        // Wait for near end
        // Trigger track 2
        // Verify no gap in audio
        // Verify metadata updated
    }

    func testSampleRateChange() {
        // Play 44.1kHz track
        // Transition to 48kHz track
        // Verify smooth transition
    }
}
```

### Manual Test Cases
1. ✅ Single track playback
2. ✅ Two track gapless transition
3. ✅ Album playback (10+ tracks)
4. ✅ Pause during playback
5. ✅ Seek during playback
6. ✅ Skip to next track
7. ✅ Phone call interruption
8. ✅ Route change (AirPods connect/disconnect)
9. ✅ Background/foreground
10. ✅ Lock screen controls

---

## Success Metrics

### Technical Metrics
- **Gap Duration**: < 1ms between tracks (target: 0ms)
- **Buffer Starvation**: < 0.1% occurrence rate
- **Crash Rate**: No increase from baseline
- **Memory Usage**: < 10% increase

### User Experience Metrics
- **Gapless Success Rate**: > 99% of track transitions
- **User Complaints**: < 5% increase
- **Feature Adoption**: > 80% using direct stream mode after 1 month

---

## Risk Mitigation

### High Risk Items
1. **Socket Data Reading**: Complex coordination with SlimProtoClient
   - **Mitigation**: Extensive testing, add retry logic

2. **Buffer Management**: Potential starvation or overflow
   - **Mitigation**: Adaptive buffering, monitoring

3. **Format Decoder Bugs**: Corrupted audio output
   - **Mitigation**: Validate PCM data, test with many files

### Medium Risk Items
1. **Memory Leaks**: Long playback sessions
   - **Mitigation**: Instruments profiling, automated leak detection

2. **CPU Usage**: Decoding overhead
   - **Mitigation**: Profile decoder performance, optimize

---

## Timeline Summary

| Phase | Duration | Deliverable | Risk |
|-------|----------|-------------|------|
| 1. Foundation | 2 weeks | Classes created, feature flags | Low |
| 2. Push Stream | 2 weeks | BASS push streams working | Low |
| 3. Decoders | 2 weeks | Format decoders implemented | Medium |
| 4. SlimProto | 2 weeks | Socket integration | High |
| 5. Playback | 2 weeks | Audio playing through push | Medium |
| 6. Gapless | 2 weeks | Sample-perfect transitions | Medium |
| 7. Polish | 2 weeks | Edge cases handled | Low |
| 8. Rollout | 2 weeks | Production deployment | Medium |
| **Total** | **16 weeks** | **Gapless playback in production** | |

---

## Conclusion

This migration plan provides:
- ✅ **Zero downtime**: Existing functionality preserved throughout
- ✅ **Incremental progress**: Each phase delivers testable value
- ✅ **Easy rollback**: Feature flags enable quick reversion
- ✅ **Hybrid approach**: Supports both gapless and HTTP streaming
- ✅ **Professional quality**: Matches Squeezebox reference implementation

The key insight is **not replacing** the existing system, but **augmenting** it with a parallel gapless path that can be enabled gradually and selectively.
