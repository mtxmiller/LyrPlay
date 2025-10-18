# BASS Buffer-Level Gapless Playback Analysis

## Executive Summary

**YES - You're absolutely right!** For proper gapless playback, we should be using BASS at the **buffer/push stream level** and controlling track transitions based on buffer state, exactly like squeezelite does.

## Current Problem

LyrPlay currently uses `BASS_StreamCreateURL()` which:
- Creates a **pull stream** (BASS fetches data internally)
- Doesn't give us buffer-level control
- Requires `BASS_ChannelStop()` → `BASS_ChannelFree()` → create new stream for each track
- This approach inherently creates audio gaps during track transitions

## Squeezelite's Gapless Approach (Reference Implementation)

### Key Architecture Components

1. **Single Output Buffer** (`outputbuf`)
   - Circular buffer that holds decoded PCM data
   - Both decoder and audio output work from the same buffer
   - Tracks are **concatenated** in the buffer seamlessly

2. **Track Boundary Markers**
   ```c
   output.track_start = pointer_to_next_track_in_buffer;
   ```
   - Decoder writes data continuously
   - Sets `track_start` pointer when beginning new track data
   - Output thread detects `track_start` when playback reaches it

3. **Buffer-Level Transition Handling** (output.c:126-169)
   ```c
   if (output.track_start == outputbuf->readp) {
       // We've reached the next track!
       // Handle sample rate changes if needed
       if (output.current_sample_rate != output.next_sample_rate) {
           set_sample_rate(output.next_sample_rate);
       }

       output.frames_played = 0;
       output.track_started = true;
       output.current_sample_rate = output.next_sample_rate;
       output.current_replay_gain = output.next_replay_gain;
       output.track_start = NULL;  // Clear marker
   }
   ```

4. **Crossfade Support**
   - Overlap old track end with new track start in buffer
   - Mix audio samples with fade curves
   - Truly gapless audio

## BASS Library Support for This Approach

### 1. **Push Streams** - `BASS_StreamCreate()`

From BASS documentation (`BASS_StreamCreate.html`):
```c
HSTREAM BASS_StreamCreate(
    DWORD freq,           // Sample rate
    DWORD chans,          // Channels (1=mono, 2=stereo)
    DWORD flags,          // BASS_STREAM_DECODE, etc.
    STREAMPROC *proc,     // Callback for pull, or STREAMPROC_PUSH
    void *user            // User data
);
```

**Key Flag**: `STREAMPROC_PUSH`
- Creates a push stream where **we** control data flow
- Use `BASS_StreamPutData()` to feed decoded audio
- Perfect for gapless since we control the entire buffer

### 2. **Feeding Data** - `BASS_StreamPutData()`

From BASS documentation (`BASS_StreamPutData.html`):
```c
DWORD BASS_StreamPutData(
    HSTREAM handle,
    void *buffer,       // PCM data to add
    DWORD length        // Length in bytes
);
```

**Critical Features**:
- "As much data as possible will be placed in the stream's playback buffer"
- "Any remainder will be queued for when more space becomes available"
- **Returns**: Amount of data currently queued
- Can check buffer level to know when to decode more

**Gapless Behavior**:
```c
// Track 1 ending - keep pushing data
BASS_StreamPutData(stream, track1_final_data, length);

// Track 2 beginning - just keep pushing!
BASS_StreamPutData(stream, track2_initial_data, length);
// ^^ No gap! Audio is continuous in the buffer
```

### 3. **Sync Points** - `BASS_ChannelSetSync()`

From BASS documentation (`BASS_ChannelSetSync.html`):

**BASS_SYNC_POS** - Callback when playback reaches specific byte position:
```c
BASS_ChannelSetSync(stream,
    BASS_SYNC_POS | BASS_SYNC_MIXTIME,  // Mixtime = immediate callback
    byte_position,                        // Position to trigger
    MySyncProc,                          // Callback function
    user_data);
```

**BASS_SYNC_END** - Callback when stream ends:
```c
BASS_ChannelSetSync(stream,
    BASS_SYNC_END,
    0,
    TrackEndProc,
    NULL);
```

**BASS_SYNC_STALL** - Callback when buffer starves:
```c
BASS_ChannelSetSync(stream,
    BASS_SYNC_STALL,
    0,
    StallProc,
    NULL);

void CALLBACK StallProc(HSYNC handle, DWORD channel, DWORD data, void *user) {
    if (data == 0) {
        // Stalled - not enough data!
        os_log("⚠️ Buffer starvation - decode faster!");
    } else {
        // Resumed - playback continued
        os_log("✅ Buffer resumed");
    }
}
```

### 4. **Buffer Monitoring** - `BASS_ChannelGetData()`

```c
// Check how much data is buffered (not playing it)
DWORD buffered = BASS_ChannelGetData(stream, NULL, BASS_DATA_AVAILABLE);
```

Returns bytes of data in playback buffer - critical for knowing when to decode more.

## Proposed LyrPlay Architecture

### High-Level Design

```
SlimProto STRM Command
        ↓
AudioStreamDecoder (NEW)
    │
    ├─→ Decode chunk (FLAC/MP3/etc)
    ├─→ BASS_StreamPutData(decoded_pcm)
    ├─→ Monitor buffer level
    └─→ Request more data when needed
        ↓
BASS Push Stream (SINGLE INSTANCE)
    │
    └─→ Continuous playback buffer
        ↓
    iOS Audio Output
```

### Implementation Components

#### 1. **AudioStreamDecoder** (New Class)
```swift
class AudioStreamDecoder {
    private var bassStream: DWORD = 0
    private var currentFormat: AudioFormat?
    private var decodeQueue: DispatchQueue
    private var isDecoding: Bool = false

    // Track boundary tracking (like squeezelite)
    private var trackBoundaryPosition: UInt64?
    private var nextTrackMetadata: TrackMetadata?

    init() {
        decodeQueue = DispatchQueue(label: "com.lyrplay.decoder",
                                     qos: .userInitiated)
    }

    func initializeStream(sampleRate: Int, channels: Int) {
        // Create push stream
        bassStream = BASS_StreamCreate(
            UInt32(sampleRate),
            UInt32(channels),
            BASS_STREAM_DECODE,  // Decode-only initially
            STREAMPROC_PUSH.rawValue,
            nil
        )

        // Set up sync for track boundaries
        BASS_ChannelSetSync(bassStream,
            BASS_SYNC_POS | BASS_SYNC_MIXTIME,
            trackBoundaryPosition ?? 0,
            trackBoundarySyncCallback,
            nil)

        // Monitor buffer starvation
        BASS_ChannelSetSync(bassStream,
            BASS_SYNC_STALL,
            0,
            bufferStallCallback,
            nil)
    }

    func pushAudioData(_ data: Data, isNewTrack: Bool) {
        if isNewTrack {
            // Mark current buffer position as track boundary
            let currentPos = BASS_ChannelGetPosition(bassStream, BASS_POS_BYTE)
            let bufferedBytes = BASS_ChannelGetData(bassStream, nil, BASS_DATA_AVAILABLE)

            trackBoundaryPosition = currentPos + UInt64(bufferedBytes)

            // Set sync for this position
            BASS_ChannelSetSync(bassStream,
                BASS_SYNC_POS | BASS_SYNC_MIXTIME,
                trackBoundaryPosition!,
                trackBoundarySyncCallback,
                nil)
        }

        // Push decoded data to BASS
        data.withUnsafeBytes { ptr in
            BASS_StreamPutData(bassStream,
                              UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                              UInt32(data.count))
        }

        // Check if we need more data
        monitorBufferLevel()
    }

    private func monitorBufferLevel() {
        let bufferedBytes = BASS_ChannelGetData(bassStream, nil, BASS_DATA_AVAILABLE)
        let threshold = sampleRate * channels * 2 * 2  // 2 seconds @ 16-bit stereo

        if bufferedBytes < threshold {
            os_log("🎵 Buffer low (%d bytes) - requesting more data", bufferedBytes)
            requestMoreStreamData()
        }
    }

    // Callback when track boundary is reached during playback
    private let trackBoundarySyncCallback: SYNCPROC = { handle, channel, data, user in
        os_log("🎯 Track boundary reached - updating metadata")
        // Update Now Playing, reset position counters, etc.
        AudioManager.shared.handleTrackTransition()
    }

    private let bufferStallCallback: SYNCPROC = { handle, channel, data, user in
        if data == 0 {
            os_log("⚠️ BUFFER STALLED - playback interrupted!")
        } else {
            os_log("✅ Buffer resumed")
        }
    }
}
```

#### 2. **Modified SlimProto Flow**
```swift
// In SlimProtoClient - STRM command handler
case "strm":
    let autostart = /* extract from command */
    let format = /* extract format */
    let httpHeaders = /* extract headers */

    if autostart == "0" {
        // Direct stream (buffer transition)
        os_log("📊 Buffer transition - continuous decode")
        decoder.markNextTrackBoundary(metadata: trackInfo)
    } else {
        // External URL (still need to handle)
        os_log("🌐 External stream - may need new stream instance")
    }

    // Start decoding from SlimProto stream
    decoder.startDecoding(from: socket, format: format)
```

#### 3. **Decoding Loop**
```swift
func startDecoding(from socket: GCDAsyncSocket, format: String) {
    decodeQueue.async {
        while self.isDecoding {
            // Read compressed data from socket
            let compressedChunk = readFromSocket(socket, maxLength: 16384)

            // Decode based on format
            let pcmData: Data
            switch format {
            case "flc":
                pcmData = decodeFLAC(compressedChunk)
            case "mp3":
                pcmData = decodeMP3(compressedChunk)
            case "ops":
                pcmData = decodeOpus(compressedChunk)
            default:
                break
            }

            // Push to BASS buffer
            self.pushAudioData(pcmData, isNewTrack: false)

            // Check if we should throttle (buffer is full)
            let buffered = BASS_ChannelGetData(self.bassStream, nil, BASS_DATA_AVAILABLE)
            if buffered > self.maxBufferSize {
                Thread.sleep(forTimeInterval: 0.05)  // Throttle
            }
        }
    }
}
```

## Benefits of Buffer-Level Approach

### 1. **True Gapless**
- No stream recreation between tracks
- Audio data is continuous in memory
- Sample-perfect transitions

### 2. **Better Buffer Management**
- Monitor exact buffer levels
- Decode on-demand based on buffer state
- Prevent buffer starvation or overflow

### 3. **Track Boundary Awareness**
```
Buffer Timeline:
[Track 1 data.....|BOUNDARY MARKER|.....Track 2 data]
                   ↑
                   Sync callback fires here
                   Update metadata, reset position, etc.
```

### 4. **Crossfade Support**
- Can overlap track data in buffer
- Implement smooth transitions
- Professional DJ-style mixing

### 5. **Sample Rate Changes**
- Detect rate change at boundary
- Reconfigure BASS output
- Seamless transition

### 6. **Position Tracking**
```swift
func getCurrentPosition() -> TimeInterval {
    // Get playback position in bytes
    let posBytes = BASS_ChannelGetPosition(bassStream, BASS_POS_BYTE)

    // Convert to seconds based on current track's start position
    let bytesIntoTrack = posBytes - trackStartPosition
    let seconds = Double(bytesIntoTrack) / Double(sampleRate * channels * 2)

    return seconds
}
```

## Migration Strategy

### Phase 1: Proof of Concept
1. Create `AudioStreamDecoder` class
2. Implement push stream with manual PCM data
3. Test gapless behavior with pre-decoded test files

### Phase 2: Format Decoders
1. Integrate FLAC decoder (BassFLAC already supports this)
2. Add MP3 decoder
3. Add Opus decoder

### Phase 3: SlimProto Integration
1. Hook up to STRM command handler
2. Implement socket → decoder → BASS pipeline
3. Handle format switching

### Phase 4: Advanced Features
1. Crossfade support
2. Replay gain per track
3. Visualization data extraction

## Comparison: Current vs. Proposed

| Feature | Current (Pull Streams) | Proposed (Push Streams) |
|---------|----------------------|------------------------|
| Gapless | ❌ Gaps during transitions | ✅ Sample-perfect |
| Buffer Control | ❌ BASS internal | ✅ Full control |
| Track Boundaries | ❌ Stream recreation | ✅ Sync callbacks |
| Crossfade | ❌ Not possible | ✅ Native support |
| Position Tracking | ⚠️ Complex with timeouts | ✅ Direct calculation |
| Memory Usage | ⚠️ Multiple stream instances | ✅ Single stream |
| CPU Efficiency | ⚠️ Stream teardown overhead | ✅ Continuous decode |

## References

### BASS Documentation
- `BASS_StreamCreate.html` - Push stream creation
- `BASS_StreamPutData.html` - Buffer feeding
- `BASS_ChannelSetSync.html` - Event callbacks
- `BASS_ChannelGetData.html` - Buffer monitoring

### Squeezelite Source
- `output.c:126-169` - Track transition logic
- `output.c:291-352` - Crossfade implementation
- `output.c:455-466` - Streaming buffer flush
- `decode.c` - Decoder → buffer pipeline

## Conclusion

**This is the correct architectural approach** for professional gapless playback. The buffer-level control that BASS provides through push streams combined with sync callbacks gives us the same capabilities as squeezelite's proven implementation.

The current URL-based stream approach is fundamentally limited for gapless playback, while the push stream approach opens up:
- True gapless transitions
- Professional crossfade
- Better resource management
- Precise playback control

This aligns perfectly with how professional audio applications (Squeezelite, Audirvana, Roon) handle gapless playback.
