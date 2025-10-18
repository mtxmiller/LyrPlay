  Current Approach: "Black Box" URL Streaming

  What We Do Today

  // We give BASS a URL
  currentStream = BASS_StreamCreateURL(
      "http://192.168.1.100:9000/stream.mp3",
      0,
      BASS_STREAM_STATUS,
      nil, nil
  )

  // BASS handles everything internally:
  // - Opens HTTP connection
  // - Downloads data
  // - Buffers data (we don't know how much)
  // - Decodes MP3 → PCM
  // - Feeds audio device
  // - Closes connection when done

  What We Can See/Control

  // Limited visibility:
  ✅ getCurrentTime() → 45.2 seconds
  ✅ getDuration() → 180.0 seconds
  ✅ getPlayerState() → "Playing"
  ✅ seek(to: 60.0) → Jump to 1 minute

  ❌ How much data is buffered? Unknown
  ❌ How much data is downloaded? Unknown
  ❌ When will buffer run out? Unknown
  ❌ Can we prevent gaps between tracks? No

  Analogy: Like riding in an Uber - you know where you're going and can see your
  progress, but you can't control the route, speed, or see the fuel level.

  ---
  Buffer-Level Approach: "Glass Box" Push Streaming

  What We Do

  // Step 1: Create an empty audio buffer
  pushStream = BASS_StreamCreate(
      44100,              // Sample rate
      2,                  // Stereo
      BASS_SAMPLE_FLOAT,
      STREAMPROC_PUSH,    // WE control data flow
      nil
  )

  // Step 2: We manually feed decoded audio data
  let pcmData = decodeMP3Chunk(compressedData)  // We do the decoding
  BASS_StreamPutData(pushStream, pcmData.bytes, pcmData.count)

  // Step 3: Monitor everything
  let buffered = BASS_ChannelGetData(pushStream, nil, BASS_DATA_AVAILABLE)
  let position = BASS_ChannelGetPosition(pushStream, BASS_POS_BYTE)

  What We Can See/Control

  // Complete visibility:
  ✅ getCurrentTime() → 45.2 seconds
  ✅ getDuration() → 180.0 seconds
  ✅ getPlayerState() → "Playing"
  ✅ seek(to: 60.0) → Jump to 1 minute

  // NEW capabilities:
  ✅ Buffered data → 524,288 bytes (3 seconds of audio)
  ✅ Playing position → byte 1,234,567
  ✅ Buffer health → "75% full, safe"
  ✅ Decode more data? → "Yes, buffer < 50%"
  ✅ Track boundary → "At byte 5,678,901"
  ✅ Prevent gaps? → YES! Keep feeding data continuously

  Analogy: Like driving your own car - you control gas, speed, route, and can see
  the fuel gauge, odometer, speedometer, etc.

  ---
  Concrete Example: Playing Two Tracks

  Current Approach (Gaps)

  Track 1 Playing:
  ┌─────────────────────────────────────┐
  │ BASS Internal Buffer (Unknown Size) │  ← We can't see this
  │ ████████████████░░░░░░░░░░░░░░░░░░ │
  │ Track 1 data...                     │
  └─────────────────────────────────────┘
          ↓
      Audio Output → "Playing track 1..."

  Track 1 Ends:
      BASS detects end internally
      ↓
  We get callback: audioPlayerDidReachEnd()
      ↓
  We call: stop() → cleanup() → BASS_StreamFree()
      ↓
  We call: playStream("http://.../track2.mp3")
      ↓
  BASS creates NEW stream, connects, buffers...
      ↓
  🔇 SILENCE GAP (100-500ms) 🔇
      ↓
  Track 2 starts playing

  Timeline:
  Track 1: ████████████████████|
  Gap:                          🔇🔇🔇
  Track 2:                         ████████████████

  Buffer-Level Approach (Gapless)

  Playing Track 1:
  ┌─────────────────────────────────────────────────┐
  │ BASS Push Buffer (WE control, WE can see)      │
  │ ████████████████████████████████████░░░░░░░░░░│
  │ Track 1 data... | ← We know position 5,678,901 │
  └─────────────────────────────────────────────────┘
          ↓
      Audio Output → "Playing track 1..."

  Server Says "Next Track":
      ↓
  We mark current buffer position as boundary:
      trackBoundary = currentPosition + bufferedBytes
      trackBoundary = 5,678,901 bytes
      ↓
  We SET SYNC at that position:
      BASS_ChannelSetSync(BASS_SYNC_POS, 5,678,901, callback)
      ↓
  We KEEP FEEDING data (Track 2 data):
  ┌─────────────────────────────────────────────────┐
  │ BASS Push Buffer (continuous!)                  │
  │ ████████████████████████████████████████████████│
  │ Track 1 end... | Track 2 start... ← NO GAP!    │
  │               ↑ Boundary at 5,678,901           │
  └─────────────────────────────────────────────────┘
      ↓
  When playback reaches byte 5,678,901:
      ↓
  Sync callback fires → Update metadata
      ↓
  🎵 CONTINUOUS AUDIO - NO GAP! 🎵

  Timeline:
  Track 1: ████████████████████|████████████████
  Track 2:                      ████████████████
           ↑ Boundary (instant metadata update, no audio gap)

  ---
  What "Buffer Level" Actually Means

  Level 1: What's in the Buffer Right Now?

  // Current approach: Unknown
  ❓ BASS has some data buffered, but we can't see how much

  // Buffer-level approach: Precise
  let buffered = BASS_ChannelGetData(pushStream, nil, BASS_DATA_AVAILABLE)
  // → 524,288 bytes = 2.97 seconds @ 44.1kHz stereo

  if buffered < threshold {
      os_log("⚠️ Buffer low - decode more data!")
      decodeMoreChunks()
  }

  Level 2: Where Are We in the Buffer?

  // Current approach: Time-based only
  let currentTime = getCurrentTime()  // → 45.2 seconds

  // Buffer-level approach: Byte-precise
  let position = BASS_ChannelGetPosition(pushStream, BASS_POS_BYTE)
  // → byte 3,968,640
  // → We can set syncs at specific byte positions
  // → Track boundaries are byte positions, not time estimates

  Level 3: What's Coming Next?

  // Current approach: No visibility
  // BASS downloads and buffers, we don't know what's next

  // Buffer-level approach: Complete control
  let bufferContents: [TrackSegment] = [
      TrackSegment(bytes: 0...5_678_901, track: "Track 1"),
      TrackSegment(bytes: 5_678_901...11_234_567, track: "Track 2"),
      TrackSegment(bytes: 11_234_567..., track: "Track 3")
  ]

  // We know EXACTLY what data is in the buffer and where

  ---
  Real-World Example: Network Hiccup

  Current Approach

  Playing: ████████ (BASS buffering internally)
  Network stalls...
  BASS internal buffer: ██░░ (getting empty, we don't know!)
  BASS internal buffer: ░░░░ (empty!)
  → BASS_SYNC_STALL callback fires
  → Audio stops (gap in playback)
  → We can't do anything proactive

  Buffer-Level Approach

  Playing: ████████
  We check: buffered = 2.1 seconds
  Network stalls...
  We check: buffered = 1.8 seconds ⚠️ Dropping!
  We check: buffered = 1.2 seconds ⚠️⚠️ Critical!
  → We proactively decode faster
  → We request more data from server
  → Buffer refills to 2.5 seconds
  → No audio gap - user doesn't notice

  ---
  The Key Insight

  Current (URL streaming):
  App → "Play this URL" → [BASS Black Box] → Audio Output
         ↑                        ↓
         └── Limited feedback ────┘

  Buffer-Level (Push streaming):
  App → Decode → Feed Data → [BASS Buffer] → Audio Output
    ↑             ↓              ↓
    ├─ Monitor Buffer Level ─────┤
    ├─ Set Boundary Syncs ───────┤
    └─ Control Everything ────────┘

  Why This Enables Gapless

  The Problem with URL Streams

  Track 1 URL → BASS Stream 1 → Must destroy when done
  Gap (while creating new stream)
  Track 2 URL → BASS Stream 2 → New connection, new buffer

  You CANNOT keep a URL stream alive across tracks because:
  - Each URL is a separate HTTP connection
  - BASS manages the connection lifecycle
  - Ending one stream = closing connection
  - Starting new stream = new connection (takes time)

  The Solution with Push Streams

  App Decoder → BASS Push Stream (SINGLE, PERMANENT)
     ↓
  Track 1 data → Feed buffer
  Track 1 ends → Mark boundary
  Track 2 data → KEEP feeding same buffer
     ↓
  Same stream, same buffer, continuous audio = GAPLESS

  Push streams can be permanent because:
  - No URL/connection tied to stream
  - WE provide the data, not BASS
  - Stream stays alive forever
  - Just keep feeding different track data

  ---
  Monitoring Examples

  What We Monitor Today

  // Time-based only
  let time = getCurrentTime()  // 45.2s
  let duration = getDuration() // 180.0s
  let state = getPlayerState() // "Playing"

  What We'd Monitor at Buffer Level

  // Everything:
  let stats = getBufferStats()
  /*
  {
      currentPosition: 3,968,640 bytes (45.2s),
      bufferedData: 524,288 bytes (2.97s),
      bufferHealth: "75% full",
      decodingRate: "448 kbps",
      expectedBufferEmpty: "in 2.97 seconds",
      trackBoundary: "at byte 5,678,901 (64.5s)",
      nextTrackQueued: true,
      stallRisk: "low"
  }
  */

  // Can make smart decisions:
  if stats.expectedBufferEmpty < 1.0 {
      boostDecodingPriority()
  }

  if stats.trackBoundaryApproaching {
      prepareNextTrackMetadata()
  }

  ---
  Summary

  URL Streaming (Current):
  - 🎬 Give BASS a URL
  - 📦 BASS handles everything (black box)
  - 👀 We see: time, duration, state
  - 🚫 We can't see: buffer level, upcoming data
  - ⛔ Result: Gaps between tracks (must destroy/recreate stream)

  Buffer-Level Streaming (Proposed):
  - 🎬 Create empty audio buffer
  - 📦 We manually feed decoded PCM data
  - 👀 We see: EVERYTHING (bytes, buffer health, positions)
  - ✅ We control: When to decode, when to feed, where boundaries are
  - 🎵 Result: Gapless (same buffer, continuous data, boundary markers)

  It's like the difference between:
  - URL: Ordering food delivery (you get updates, but no control over
  cooking/delivery)
  - Buffer: Cooking yourself (you control every step and see exactly what's
  happening)