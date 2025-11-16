# Squeezelite Gapless Architecture - Complete Reference

**Last Updated**: 2025-01-31
**Source Analysis**: squeezelite source code (opus.c, decode.c, output.c, slimproto.c)
**Purpose**: Definitive reference for implementing gapless playback compatible with LMS

---

## 1. Buffer Architecture

### Two Separate Buffers

Squeezelite maintains **two distinct circular buffers**:

#### 1.1 Stream Buffer (`streambuf`)
- **Purpose**: Stores encoded audio data from HTTP stream
- **Size**: 2MB (STREAMBUF_SIZE = 2 * 1024 * 1024)
- **Managed By**: Stream thread (stream.c)
- **Data Format**: Encoded (Opus, FLAC, MP3, etc.)
- **Pointers**:
  - `readp`: Where decoder reads from
  - `writep`: Where HTTP stream writes to

#### 1.2 Output Buffer (`outputbuf`)
- **Purpose**: Stores decoded PCM audio ready for playback
- **Size**: 3.52MB (OUTPUTBUF_SIZE = 44100 * 8 * 10)
- **Managed By**: Decode thread writes, Output thread reads
- **Data Format**: PCM (decoded audio)
- **Pointers**:
  - `readp`: Where audio output reads from (playback position)
  - `writep`: Where decoder writes to (decode position)

### Buffer Structure (from squeezelite.h:514-522)
```c
struct buffer {
    u8_t *buf;           // Base buffer address
    u8_t *readp;         // Read pointer (consumer)
    u8_t *writep;        // Write pointer (producer)
    u8_t *wrap;          // End of buffer (for circular wrapping)
    size_t size;         // Current buffer size
    size_t base_size;    // Original buffer size
    mutex_type mutex;    // Thread synchronization
};
```

---

## 2. Thread Architecture

### 2.1 Stream Thread
- **File**: stream.c
- **Purpose**: Downloads HTTP audio stream into `streambuf`
- **States**: STOPPED, DISCONNECT, STREAMING_WAIT, STREAMING_BUFFERING, STREAMING_FILE, STREAMING_HTTP
- **Key Actions**:
  - Opens HTTP connection to LMS server
  - Reads encoded audio data
  - Writes to `streambuf->writep`
  - Advances `writep` as data arrives

### 2.2 Decode Thread
- **File**: decode.c
- **Purpose**: Decodes audio from `streambuf` into `outputbuf`
- **Main Loop** (decode.c:56-121):

```c
while (running) {
    LOCK_S;
    bytes = _buf_used(streambuf);       // How much encoded data available
    toend = (stream.state <= DISCONNECT);  // Is HTTP stream done?
    UNLOCK_S;

    LOCK_O;
    space = _buf_space(outputbuf);      // How much space for decoded PCM
    UNLOCK_O;

    if (space > min_space && (bytes > codec->min_read_bytes || toend)) {
        decode.state = codec->decode();  // Decode a chunk

        if (decode.state != DECODE_RUNNING) {
            LOG_INFO("decode %s", decode.state == DECODE_COMPLETE ? "complete" : "error");
            wake_controller();  // Notify slimproto thread
        }
    }

    if (!ran) {
        usleep(100000);  // Wait 100ms if nothing to do
    }
}
```

**Key Behavior**:
- Continuously pulls encoded data from `streambuf`
- Decodes and pushes PCM to `outputbuf`
- Returns `DECODE_COMPLETE` when:
  - HTTP stream finished (`toend == true`)
  - AND decoder has no more frames (`n == 0`)

### 2.3 Output Thread
- **File**: output.c
- **Purpose**: Sends PCM from `outputbuf` to audio hardware
- **Key Actions**:
  - Reads from `outputbuf->readp`
  - Sends to audio device (ALSA/CoreAudio/etc)
  - Advances `readp` as audio plays
  - **Detects track boundaries** (see Section 4)

### 2.4 SlimProto Thread
- **File**: slimproto.c
- **Purpose**: Handles protocol communication with LMS server
- **Key Actions**:
  - Receives commands (STRM, audg, etc)
  - Sends status updates (STAT)
  - Coordinates other threads

---

## 3. Gapless Track Boundary Mechanism

### 3.1 Setting Track Boundary (Decode Thread)

**When**: New track decoder starts
**Where**: opus.c:125-151

```c
static decode_state opus_decompress(void) {
    // ... codec initialization ...

    if (decode.new_stream) {
        // Open new opus file decoder
        if ((u->of = OP(u, open_callbacks, streambuf, &cbs, NULL, 0, &err)) == NULL) {
            LOG_WARN("open_callbacks error: %d", err);
            return DECODE_COMPLETE;
        }

        LOCK_O;
        output.next_sample_rate = decode_newstream(48000, output.supported_rates);

        // CRITICAL: Mark where new track's PCM starts in output buffer
        output.track_start = outputbuf->writep;  // ← BOUNDARY SET HERE

        if (output.fade_mode) _checkfade(true);
        decode.new_stream = false;  // Clear flag
        UNLOCK_O;

        LOG_INFO("setting track_start");
    }

    // Continue decoding...
    n = OP(u, read, u->of, (opus_int16*) write_buf, frames * channels, NULL);
    // ... write to outputbuf->writep and advance writep ...
}
```

**Key Points**:
1. `decode.new_stream` flag is set by `codec_open()` when STRM received
2. Boundary (`track_start`) = current `writep` = where new track's audio will start
3. After marking, decoder continues writing track 2's PCM immediately after track 1

### 3.2 Detecting Track Boundary (Output Thread)

**When**: During playback
**Where**: output.c:126-169

```c
while (size > 0) {
    frames_t cont_frames = _buf_cont_read(outputbuf) / BYTES_PER_FRAME;

    if (output.track_start && !silence) {
        // Check if read pointer reached the boundary
        if (output.track_start == outputbuf->readp) {
            // PLAYBACK HAS REACHED THE NEW TRACK!

            LOG_INFO("track start sample rate: %u replay_gain: %u",
                     output.next_sample_rate, output.next_replay_gain);

            output.frames_played = 0;         // Reset counter
            output.track_started = true;      // ← SET FLAG FOR SLIMPROTO
            output.track_start_time = gettime_ms();
            output.current_sample_rate = output.next_sample_rate;
            output.current_replay_gain = output.next_replay_gain;
            output.track_start = NULL;        // Clear boundary marker
            break;
        }
        else if (output.track_start > outputbuf->readp) {
            // Boundary ahead - limit read to not overshoot
            cont_frames = min(cont_frames,
                             (output.track_start - outputbuf->readp) / BYTES_PER_FRAME);
        }
    }

    // Read and output audio frames...
}
```

**Key Points**:
1. Continuously checks: `readp == track_start`?
2. When equal, playback has reached new track's audio
3. Sets `track_started = true` for slimproto thread
4. Clears `track_start` to stop checking

### 3.3 Sending STMs (SlimProto Thread)

**When**: After `track_started` flag set
**Where**: slimproto.c:702-703, 755

```c
bool _sendSTMs = false;

// Check flag set by output thread
if (output.track_started) {
    _sendSTMs = true;
    output.track_started = false;  // Clear flag
}

// Later in same loop...
if (_sendSTMs) sendSTAT("STMs", 0);
```

---

## 4. Complete Gapless Flow Timeline

### Phase 1: Track 1 Playing

```
Time: 0s
┌─────────────────────────────────────────────────┐
│ Stream Thread: Downloading Track 1 (Opus)       │
│   streambuf: [======OPUS DATA=====]             │
└─────────────────────────────────────────────────┘
         ↓ HTTP data
┌─────────────────────────────────────────────────┐
│ Decode Thread: Decoding Track 1                 │
│   Reads from: streambuf->readp                   │
│   Writes to:  outputbuf->writep (advancing)      │
│   outputbuf:  [===PCM Track 1===]               │
└─────────────────────────────────────────────────┘
         ↓ PCM data
┌─────────────────────────────────────────────────┐
│ Output Thread: Playing Track 1                  │
│   Reads from: outputbuf->readp (advancing)       │
│   Playing:    Track 1 audio                      │
└─────────────────────────────────────────────────┘
```

### Phase 2: Track 1 Decode Completes

```
Time: ~17s (HTTP download complete, all 122s decoded)
┌─────────────────────────────────────────────────┐
│ Stream Thread: HTTP Finished                     │
│   stream.state = DISCONNECT                      │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│ Decode Thread: Returns DECODE_COMPLETE          │
│   Condition: toend==true && n==0                 │
│   Action: wake_controller()                      │
│   outputbuf: [===ALL 122s of Track 1 PCM===]    │
│              writep at END of track 1 ^          │
└─────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────┐
│ SlimProto Thread: Sends STMd                    │
│   Message to server: "decoder ready"             │
└─────────────────────────────────────────────────┘
```

**Server Response**:
- Calls `playerReadyToStream()`
- Queues next track in playlist
- Sends new STRM command with track 2 URL

### Phase 3: Track 2 Starts Decoding (Gapless!)

```
Time: ~18s
┌─────────────────────────────────────────────────┐
│ SlimProto Thread: Receives STRM (Track 2)      │
│   Calls: codec_open()                            │
│   Sets: decode.new_stream = true                 │
└─────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────┐
│ Stream Thread: Downloading Track 2              │
│   streambuf: [======OPUS DATA Track 2=====]     │
└─────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────┐
│ Decode Thread: Starts Track 2 Decoder           │
│   Detects: decode.new_stream == true             │
│   SETS BOUNDARY: track_start = outputbuf->writep │
│              (writep is at END of Track 1)       │
│   outputbuf: [===Track 1 PCM===][writep]        │
│              Clears: decode.new_stream = false   │
│   Then decodes Track 2:                          │
│   outputbuf: [===Track 1 PCM===][Track 2 PCM]   │
│              track_start ^      writep advances→ │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│ Output Thread: Still Playing Track 1            │
│   outputbuf: [===Track 1 PCM===][Track 2 PCM]   │
│              readp ^         track_start ^       │
│   Playback at: ~18s into track 1                 │
└─────────────────────────────────────────────────┘
```

**Key**: Track 2's PCM is written IMMEDIATELY after Track 1's PCM in same buffer!

### Phase 4: Playback Reaches Boundary

```
Time: ~122s (Track 1 finishes)
┌─────────────────────────────────────────────────┐
│ Output Thread: Detects Boundary Crossing        │
│   outputbuf: [===Track 1 PCM===][Track 2 PCM]   │
│                            readp ^               │
│                            track_start ^         │
│   Condition: readp == track_start                │
│   SETS FLAG: output.track_started = true         │
│   CLEARS: track_start = NULL                     │
└─────────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────────┐
│ SlimProto Thread: Sends STMs                    │
│   Detects: output.track_started == true          │
│   Sends: STAT "STMs"                             │
│   Clears: output.track_started = false           │
└─────────────────────────────────────────────────┘
```

**Server Response**:
- Calls `playerTrackStarted()`
- Updates Material UI to show Track 2
- Updates timing/metadata

### Phase 5: Track 2 Playing

```
Time: 122s+
┌─────────────────────────────────────────────────┐
│ Output Thread: Playing Track 2 Seamlessly       │
│   outputbuf: [===Track 1 PCM===][Track 2 PCM]   │
│                            readp advancing→      │
│   NO AUDIO GAP - continuous PCM data!            │
└─────────────────────────────────────────────────┘
```

---

## 5. Critical Timing Relationships

### 5.1 Decode Time vs Playback Time

For a 122 second track:
- **HTTP Download Time**: ~15-20 seconds (network speed dependent)
- **Decode Time**: ~15-20 seconds (decode happens as data arrives)
- **Playback Time**: 122 seconds (real-time audio playback)

**Decoding is MUCH faster than playback!**

```
Real Time:     0s    15s         122s
               |-----|-----------|
HTTP:          [====DONE====]
Decode:        [====DONE====]
Playback:      [=============DONE=============]
```

This creates ~100+ seconds of buffer time to queue next track!

### 5.2 Buffer State During Gapless

```
Time 0s (Track 1 starts):
outputbuf: [Track1_PCM...........................]
           ^readp  ^writep advancing→

Time 17s (Track 1 decode complete):
outputbuf: [===Track1_PCM_ALL_122s===]
           ^readp (~17s in)          ^writep

Time 18s (Track 2 starts decoding):
outputbuf: [===Track1_PCM_ALL===][Track2_PCM...]
           ^readp (~18s in)  ^track_start  ^writep advancing→

Time 122s (Boundary reached):
outputbuf: [===Track1_PCM===][===Track2_PCM===]
                         ^readp==track_start
                         → STMs sent!
```

---

## 6. Server-Side Protocol Flow

### 6.1 STRM Command Structure

Server sends STRM to start streaming a track:
```
STRM <length>
  u8  command       's' = stream, 'q' = query, etc
  u8  autostart     '0' = paused, '1' = autostart, '2' = direct, '3' = continue
  u8  format        'u' = Opus (0x75), 'f' = FLAC, etc
  u8  pcmsamplesize
  u8  pcmsamplerate
  u8  pcmchannels
  u8  pcmendian
  u8  threshold
  u8  spdif_enable
  u8  trans_period
  u8  trans_type
  u32 replay_gain
  u16 server_port
  u32 server_ip
  ... HTTP request header
```

### 6.2 STAT (STMd) - Decoder Complete

**Sent by client** when decode thread returns `DECODE_COMPLETE`:
- Signals: "I finished decoding current track"
- Server action: Queue next track, send new STRM
- **Does NOT mean playback finished** - just decoding!

### 6.3 STAT (STMs) - Track Started

**Sent by client** when playback reaches track boundary:
- Signals: "New track audio is NOW PLAYING"
- Server action: Update UI, metadata, timing
- This is when user should see track change

### 6.4 Server Event Flow (from Squeezebox2.pm:148-169)

```perl
if ($code eq 'STMd') {
    $client->readyToStream(1);
    $client->controller()->playerReadyToStream($client);
    # → Queues next track, sends STRM
}
elsif ($code eq 'STMs') {
    $client->controller()->playerTrackStarted($client);
    # → Updates Material UI, metadata
}
```

---

## 7. Key Squeezelite Design Principles

### 7.1 Separation of Concerns
- **Stream thread**: Only downloads
- **Decode thread**: Only decodes
- **Output thread**: Only plays
- **SlimProto thread**: Only communicates

### 7.2 Producer-Consumer Pattern
- Buffers connect threads
- Mutexes protect shared state
- Threads run independently

### 7.3 Pointer-Based Boundaries
- `writep` = where producer writes next
- `readp` = where consumer reads next
- Boundary = snapshot of `writep` at specific moment
- Detection = comparing `readp` to boundary

### 7.4 Flag-Based Communication
- `decode.new_stream` = "new track starting"
- `output.track_started` = "boundary crossed"
- Flags set by one thread, read by another

---

## 8. Critical Implementation Requirements

For LMS-compatible gapless playback:

### 8.1 MUST Track Write Position
- Know where decoded audio is being written
- Ability to "snapshot" this position as boundary

### 8.2 MUST Track Read Position
- Know where playback is currently reading from
- Ability to compare read position to boundary

### 8.3 MUST Detect Boundary Crossing
- Check when read position reaches boundary
- Trigger at exact moment (not before/after)

### 8.4 MUST Send Correct Protocol Messages
- STMd when decoder finishes (not when playback finishes!)
- STMs when playback reaches boundary (not when decoder starts!)

### 8.5 MUST Preserve Buffer on Gapless
- Track 2 audio appended after Track 1 in same buffer
- No flushing between tracks
- Continuous PCM data

### 8.6 MUST Handle Manual Skip Differently
- Manual skip: Flush buffer, send stop/start
- Gapless: Preserve buffer, send STMd/STMs

---

## 9. Common Implementation Pitfalls

### 9.1 Confusing Decode Position with Playback Position
❌ **WRONG**: Sending STMs when decoder starts track 2
✅ **RIGHT**: Sending STMs when playback reaches track 2 audio

### 9.2 Marking Boundary at Playback Position
❌ **WRONG**: `boundary = playback_position + buffered`
✅ **RIGHT**: `boundary = write_position` (where we've written to)

### 9.3 Flushing Buffer on Gapless
❌ **WRONG**: Flush buffer when new STRM received
✅ **RIGHT**: Preserve buffer, append new track's audio

### 9.4 Sending STMd Too Early/Late
❌ **WRONG**: Send STMd when HTTP completes
✅ **RIGHT**: Send STMd when decoder has no more frames AND HTTP done

### 9.5 Not Resetting Counters at Boundary
❌ **WRONG**: Position tracking continues from track 1 start
✅ **RIGHT**: Reset position counter when boundary crossed

---

## 10. Reference Source Code Locations

### Key Files in Squeezelite:
- `decode.c:56-121` - Main decode loop
- `opus.c:119-151` - Track boundary marking
- `output.c:126-169` - Boundary detection and STMs trigger
- `slimproto.c:702-755` - STMs sending logic
- `squeezelite.h:514-522` - Buffer structure
- `squeezelite.h:646-695` - Output state structure

### Key Files in LMS (slimserver):
- `Slim/Player/Squeezebox2.pm:148-169` - Status message handling
- `Slim/Networking/Slimproto.pm:740-746` - Protocol documentation

---

**End of Reference Document**
