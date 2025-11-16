# BASS Modernization Roadmap

**Branch:** `feature/bass-modernization`
**Goal:** Modernize LyrPlay audio architecture for reliability and gapless playback
**Start Date:** 2025-01-16
**Status:** Planning

---

## Overview

This roadmap takes LyrPlay from manual audio session management to a modern, BASS-managed architecture with buffer-level gapless playback support.

### Three Major Phases:

1. **Phase 1: BASS Audio Session Management** (~1-2 days)
   - Remove manual AVAudioSession management
   - Let BASS handle route changes and interruptions
   - Fix "sometimes works" reliability issues
   - **Checkpoint:** Stable playback with simpler code

2. **Phase 2: BASS Version Upgrade** (~1 day)
   - Replace CBass package BASS with latest local version
   - Verify compatibility and improvements
   - **Checkpoint:** Latest BASS working with current architecture

3. **Phase 3: Buffer-Level Gapless Playback** (~3-5 days)
   - Implement push stream architecture
   - Add track boundary markers
   - Achieve sample-perfect gapless transitions
   - **Checkpoint:** True gapless playback like squeezelite

---

## Phase 1: BASS Audio Session Management

### Goals
- ✅ Eliminate timing race conditions
- ✅ Fix AirPods/CarPlay "sometimes works" bugs
- ✅ Reduce code complexity by ~300 lines
- ✅ Match industry standard (Spotify, Apple Music approach)

### Prerequisites
- [ ] Current main branch is stable
- [ ] Create feature branch: `feature/bass-modernization`
- [ ] Save current working state (can revert if needed)

### Step 1.1: Remove BASS Session Configuration

**Files:** `AudioPlayer.swift`

**Changes:**
```swift
// REMOVE (line 71-72):
// BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), DWORD(BASS_IOS_SESSION_DISABLE))

// REMOVE (line 157):
// BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), DWORD(BASS_IOS_SESSION_DISABLE))

// In setupCBass():
private func setupCBass() {
    // BASS handles iOS audio session automatically (default behavior)
    // No session configuration needed

    let result = BASS_Init(-1, 44100, 0, nil, nil)
    // ... rest unchanged
}
```

**Test:** App compiles, BASS initializes successfully

---

### Step 1.2: Remove Manual Session Functions

**Files:** `AudioPlayer.swift`

**Remove entirely:**
- `setupManualAudioSession()` (lines 127-129)
- `configureAudioSessionIfNeeded()` (lines 132-134)
- `reinitializeBASS()` function (lines 118-125 + entire 50-line implementation)

**Replace `handleAudioRouteChange()` with:**
```swift
func handleAudioRouteChange() {
    os_log(.info, log: logger, "🔀 Audio route changed - BASS handling automatically")
    // BASS automatically switches audio device - no action needed
}
```

**Test:** App compiles, references to removed functions are gone

---

### Step 1.3: Simplify PlaybackSessionController

**Files:** `PlaybackSessionController.swift`

**Remove entirely:**
- `ensureActive()` function (lines 137-154)
- `deactivateIfNeeded()` function (lines 156-167)

**Find all calls to these functions and:**
- `ensureActive(context: .userInitiatedPlay)` → **DELETE** (BASS activates automatically)
- `ensureActive(context: .serverResume)` → **DELETE**
- `ensureActive(context: .backgroundRefresh)` → **DELETE**
- `deactivateIfNeeded()` → **DELETE**

**Test:** App compiles, no calls to removed functions remain

---

### Step 1.4: Simplify Route Change Handler

**Files:** `PlaybackSessionController.swift`

**In `handleRouteChange()` - REMOVE all BASS reinit logic:**

```swift
// DELETE this entire section (lines 363-405):
if !isCarPlayEvent && !isEnteringPhoneCall {
    if reason == .oldDeviceUnavailable {
        workQueue.async { [weak self] in
            // ... deactivate/reactivate/reinit dance
        }
    } else {
        workQueue.async { [weak self] in
            // ... reinit BASS
        }
    }
}

// REPLACE WITH simple logging:
if previousHadPhoneRoute && !currentHasPhoneRoute {
    os_log(.info, log: logger, "📞 Exited phone call - BASS handling route automatically")
}
```

**Keep:**
- Route change detection and logging
- Phone call state tracking (for SlimProto commands)
- Interruption context resume logic (lines 408-417)
- CarPlay event handling (simplified)
- AirPods disconnect pause command (line 429-435)

**Test:** App compiles, route changes logged but no BASS reinit

---

### Step 1.5: Simplify Interruption Handler

**Files:** `PlaybackSessionController.swift`

**In `handleInterruption()` - REMOVE session management:**

```swift
case .began:
    // Keep: interruption context tracking
    // Keep: SlimProto pause command
    // REMOVE: Nothing to remove here (already just sends commands)

case .ended:
    // REMOVE (lines 307-317):
    // ensureActive(context: .serverResume)
    // playbackController?.handleAudioRouteChange()

    // KEEP: SlimProto play command
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.slimProtoProvider?()?.sendLockScreenCommand("play")
    }
```

**Test:** App compiles, interruptions send SlimProto commands only

---

### Step 1.6: Simplify CarPlay Handlers

**Files:** `PlaybackSessionController.swift`

**In `handleCarPlayConnected()`:**
```swift
private func handleCarPlayConnected() {
    guard !shouldThrottleCarPlayEvent() else { return }
    refreshRemoteCommandCenter()
    endBackgroundTask()
    os_log(.info, log: logger, "🚗 CarPlay connected - BASS handling route automatically")

    // REMOVED: All session deactivate/reactivate/reinit logic
    wasPlayingBeforeCarPlayDetach = false
}
```

**In `handleCarPlayDisconnected()`:**
```swift
private func handleCarPlayDisconnected() {
    guard !shouldThrottleCarPlayEvent() else { return }
    os_log(.info, log: logger, "🚗 CarPlay disconnected - pausing playback")
    wasPlayingBeforeCarPlayDetach = playbackController?.isPlaying ?? false
    beginBackgroundTask(named: "CarPlayDisconnect")

    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }

        // REMOVED: Session deactivate/reactivate/reinit logic
        // Just send pause command
        if let coordinator = self.slimProtoProvider?() {
            coordinator.sendLockScreenCommand("pause")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.endBackgroundTask()
        }
    }
}
```

**Test:** App compiles, CarPlay handling simplified

---

### Step 1.7: Testing Phase 1

**Critical Tests:**

1. **Basic Playback:**
   - [ ] App starts and connects to server
   - [ ] Music plays through speaker
   - [ ] Lock screen shows metadata
   - [ ] Lock screen play/pause works

2. **Route Changes:**
   - [ ] Connect AirPods mid-playback → audio switches automatically
   - [ ] Disconnect AirPods → audio switches to speaker automatically
   - [ ] Connect to CarPlay → audio switches automatically
   - [ ] Disconnect CarPlay → audio switches to speaker, server paused

3. **Interruptions:**
   - [ ] Phone call (speaker) → pauses, resumes after call
   - [ ] Phone call (AirPods) → pauses, resumes with correct audio route
   - [ ] Siri text message → pauses, resumes automatically
   - [ ] Timer/alarm → handles correctly

4. **Edge Cases:**
   - [ ] Rapid AirPods connect/disconnect
   - [ ] Background/foreground app during playback
   - [ ] Network disconnect/reconnect during playback
   - [ ] Multiple tracks playing through transitions

**Success Criteria:**
- ✅ All tests pass consistently (no "sometimes works")
- ✅ No audio route confusion
- ✅ Lock screen controls work reliably
- ✅ Simpler code (300 fewer lines)

**Failure Criteria:**
- ❌ Lock screen controls stop working
- ❌ Audio doesn't switch routes
- ❌ Worse reliability than before

**Rollback Plan:**
```bash
git checkout main
git branch -D feature/bass-modernization
```

**Phase 1 Checkpoint:** If successful, commit and push. If unsuccessful, rollback and document findings.

---

## Phase 2: BASS Version Upgrade

### Goals
- ✅ Use latest BASS library (from working folder)
- ✅ Get latest iOS fixes and improvements
- ✅ Ensure compatibility with Phase 1 changes

### Prerequisites
- [ ] Phase 1 is stable and committed
- [ ] Locate latest BASS libraries in working folder
- [ ] Backup current CBass package configuration

### Step 2.1: Identify Current vs Latest BASS

**Current BASS version:**
```bash
# Check CBass package
ls ~/.swiftpm/checkouts/CBass/
# Or in Xcode: File → Swift Packages → Package Dependencies
```

**Latest BASS location:**
```bash
# User said it's in working folder
ls ~/Downloads/bass*-ios*/
# Expected: bass.h, libbass.a, bassflac.h, libbassflac.a, etc.
```

**Document versions:**
- Current: bass24-ios (from CBass package)
- Latest: bass24-ios (from ~/Downloads/bass24-ios2/ or similar)

---

### Step 2.2: Update BASS Libraries

**Option A: Update CBass Package (Preferred)**

Fork CBass package and update with latest libraries:
```bash
# Fork https://github.com/Treata11/CBass
# Clone your fork
# Replace bass.xcframework and plugin frameworks
# Update Package.swift if needed
# Point LyrPlay to your fork
```

**Option B: Local Framework Integration**

Add BASS frameworks directly to project:
```bash
# Copy from ~/Downloads/bass24-ios2/
# Add to Frameworks/ folder
# Update Xcode project to link directly
# Remove CBass package dependency
```

**Recommended:** Option B for now (faster iteration)

---

### Step 2.3: Update Project Configuration

**Files:** `LMS_StreamTest.xcodeproj/project.pbxproj`

**Steps:**
1. Copy latest BASS libraries to `Frameworks/` folder
2. Remove CBass package dependency
3. Add framework search paths
4. Link binary with libraries

**Changes:**
```
# Add to Framework Search Paths:
$(PROJECT_DIR)/Frameworks

# Link binaries:
libbass.a
libbassflac.a
libbassopus.a

# Header Search Paths:
$(PROJECT_DIR)/BASS_Headers
```

---

### Step 2.4: Update Swift Imports

**Files:** `AudioPlayer.swift`, `AudioManager.swift`

**Change from:**
```swift
import Bass
import BassFLAC
import BassOpus
```

**To:**
```swift
// Use local headers via bridging header
// No import statements needed if using bridging header
```

**Create bridging header if needed:**
`LMS_StreamTest-Bridging-Header.h`:
```c
#import "bass.h"
#import "bassflac.h"
#import "bassopus.h"
```

---

### Step 2.5: Testing Phase 2

**Tests:**
- [ ] App compiles with new BASS version
- [ ] All Phase 1 tests still pass
- [ ] Check BASS version in logs: `BASS_GetVersion()`
- [ ] Verify FLAC playback works
- [ ] Verify Opus playback works
- [ ] Verify route changes still work
- [ ] Verify interruptions still work

**Success Criteria:**
- ✅ All Phase 1 functionality preserved
- ✅ Latest BASS version confirmed
- ✅ No new bugs introduced

**Phase 2 Checkpoint:** Commit BASS upgrade

---

## Phase 3: Buffer-Level Gapless Playback

**🔄 IN PROGRESS** - Manual skip working! Need to implement natural track end detection for true gapless.

### Current Status (as of 2025-01-30)

**✅ COMPLETED:**
- Push stream architecture with decoder loop (URL → decoder → push stream)
- Track boundary markers with BASS sync callbacks
- Position tracking (per-track, resets at boundaries)
- Pause/resume (works correctly with `hasValidStream()` check)
- **Manual track skip** with buffer flush (`BASS_ChannelSetPosition(0)`)
- **Sample rate matching** (detects actual format, recreates push stream if needed)
- Material interface integration (STMc/STMs messages, position updates)

**⚠️ CURRENT BEHAVIOR:**
- **Manual skip:** ✅ Audio changes immediately (buffer flushed)
- **Natural track end:** ❌ Not implemented (needs detection + queue mechanism)

**📋 REMAINING FOR TRUE GAPLESS:**
1. Detect natural track end vs manual skip
2. On natural end: Don't flush buffer, let old audio finish
3. Queue next track's decoder while current plays
4. Boundary marker triggers metadata update (not audio change)
5. Seamless audio transition (0ms gap)

### Goals
- ✅ Implement push stream architecture
- ✅ Add track boundary markers
- ⏳ Achieve true gapless playback (0ms gaps) - **In Progress**
- ⏳ Match squeezelite quality - **In Progress**

### Prerequisites
- [x] Phase 1 & 2 stable
- [x] Read `/docs/bass-gapless-buffer-analysis.md`
- [x] Read `/docs/gapless-migration-plan.md`

### Step 3.1: Design AudioStreamDecoder Class

**New file:** `AudioStreamDecoder.swift`

**Purpose:**
- Manage single BASS push stream
- Decode audio chunks from SlimProto
- Feed decoded PCM to BASS via `BASS_StreamPutData()`
- Track buffer levels
- Set track boundary sync markers

**Key methods:**
```swift
class AudioStreamDecoder {
    private var pushStream: HSTREAM = 0

    func initializePushStream(sampleRate: Int, channels: Int)
    func feedDecodedAudio(_ data: Data, isNewTrack: Bool)
    func monitorBufferLevel() -> Int
    func setTrackBoundaryMarker(at position: UInt64)
    func cleanup()
}
```

---

### Step 3.2: Implement Push Stream Creation

**In AudioStreamDecoder.swift:**

```swift
func initializePushStream(sampleRate: Int, channels: Int) {
    // Create push stream (we feed it, not URL-based)
    pushStream = BASS_StreamCreate(
        UInt32(sampleRate),
        UInt32(channels),
        DWORD(BASS_SAMPLE_FLOAT),  // 32-bit float like squeezelite
        STREAMPROC_PUSH,            // We push data, BASS doesn't pull
        nil
    )

    guard pushStream != 0 else {
        let error = BASS_ErrorGetCode()
        os_log(.error, "❌ Push stream creation failed: %d", error)
        return
    }

    // Set up stall detection
    BASS_ChannelSetSync(pushStream, DWORD(BASS_SYNC_STALL), 0,
                       stallCallback, nil)

    os_log(.info, "✅ Push stream created: %d Hz, %d channels",
           sampleRate, channels)
}
```

---

### Step 3.3: Implement Buffer Feeding

**In AudioStreamDecoder.swift:**

```swift
func feedDecodedAudio(_ data: Data, isNewTrack: Bool) {
    guard pushStream != 0 else { return }

    if isNewTrack {
        // Calculate current buffer position
        let currentPos = BASS_ChannelGetPosition(pushStream, DWORD(BASS_POS_BYTE))
        let bufferedBytes = BASS_ChannelGetData(pushStream, nil, BASS_DATA_AVAILABLE)
        let boundaryPosition = currentPos + UInt64(bufferedBytes)

        // Set sync for track boundary
        BASS_ChannelSetSync(pushStream,
                           DWORD(BASS_SYNC_POS | BASS_SYNC_MIXTIME),
                           boundaryPosition,
                           trackBoundaryCallback,
                           nil)

        os_log(.info, "🎯 Track boundary marker set at position: %llu", boundaryPosition)
    }

    // Push decoded PCM data to BASS buffer
    data.withUnsafeBytes { ptr in
        let pushed = BASS_StreamPutData(pushStream,
                                       UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                                       UInt32(data.count))

        if pushed == DWORD(-1) {
            os_log(.error, "❌ StreamPutData failed: %d", BASS_ErrorGetCode())
        }
    }

    // Monitor buffer health
    monitorBufferLevel()
}

func monitorBufferLevel() -> Int {
    let buffered = BASS_ChannelGetData(pushStream, nil, BASS_DATA_AVAILABLE)
    let threshold = sampleRate * channels * 4 * 2  // 2 seconds of float samples

    if buffered < threshold {
        os_log(.warning, "⚠️ Buffer low: %d bytes (threshold: %d)", buffered, threshold)
        // Request more data from server
        delegate?.requestMoreStreamData()
    }

    return Int(buffered)
}
```

---

### Step 3.4: Implement Track Boundary Detection

**In AudioStreamDecoder.swift:**

```swift
private let trackBoundaryCallback: SYNCPROC = { handle, channel, data, user in
    os_log(.info, "🎯 Track boundary reached - updating metadata")

    // Notify delegate to update Now Playing, reset counters, etc.
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: NSNotification.Name("TrackBoundaryReached"),
            object: nil
        )
    }
}

private let stallCallback: SYNCPROC = { handle, channel, data, user in
    if data == 0 {
        os_log(.error, "⚠️ Buffer stalled - playback interrupted!")
    } else {
        os_log(.info, "✅ Buffer resumed after stall")
    }
}
```

---

### Step 3.5: Integrate with SlimProto

**Files:** `SlimProtoCommandHandler.swift`

**Modified STRM command handling:**

```swift
case "strm":
    let autostart = payload[1]
    let format = payload[2]

    if autostart == Character("0").asciiValue {
        // Direct stream - use push stream for gapless
        os_log(.info, "📊 Direct stream - using push stream for gapless")

        // Initialize decoder if needed
        if streamDecoder == nil {
            streamDecoder = AudioStreamDecoder()
            streamDecoder?.initializePushStream(sampleRate: 44100, channels: 2)
        }

        // Start feeding data from socket
        startDecodingFromSocket(format: format)

    } else {
        // HTTP URL - use traditional URL stream (radio, external)
        os_log(.info, "🌐 HTTP stream - using URL stream")
        audioPlayer.playStreamWithFormat(urlString: url, format: format)
    }
```

---

### Step 3.6: Implement Decoder Loop

**In AudioStreamDecoder.swift:**

```swift
func startDecodingFromSocket(socket: GCDAsyncSocket, format: String) {
    decodeQueue.async { [weak self] in
        guard let self = self else { return }

        while self.isDecoding {
            // Read compressed chunk from socket
            let compressedData = self.readChunkFromSocket(socket, maxBytes: 16384)

            guard !compressedData.isEmpty else { break }

            // Decode based on format
            let pcmData: Data
            switch format {
            case "flc":
                pcmData = self.decodeFLAC(compressedData)
            case "mp3":
                pcmData = self.decodeMP3(compressedData)
            case "ops":
                pcmData = self.decodeOpus(compressedData)
            default:
                os_log(.error, "❌ Unsupported format: %{public}s", format)
                continue
            }

            // Feed to push stream
            self.feedDecodedAudio(pcmData, isNewTrack: false)

            // Throttle if buffer is full
            let buffered = BASS_ChannelGetData(self.pushStream, nil, BASS_DATA_AVAILABLE)
            if buffered > self.maxBufferSize {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
```

---

### Step 3.7: Testing Phase 3

**Gapless Tests:**

1. **Basic Gapless:**
   - [ ] Play album with 10+ tracks
   - [ ] Listen for gaps between tracks
   - [ ] Measure gap duration (should be 0ms)

2. **Track Boundary Detection:**
   - [ ] Verify metadata updates at exact track boundaries
   - [ ] Verify position resets correctly per track
   - [ ] Verify Now Playing updates in sync

3. **Buffer Management:**
   - [ ] Monitor buffer levels in logs
   - [ ] Verify no buffer starvation
   - [ ] Verify no excessive buffering

4. **Format Support:**
   - [ ] Test FLAC gapless playback
   - [ ] Test MP3 gapless playback
   - [ ] Test Opus gapless playback

5. **Edge Cases:**
   - [ ] Skip tracks rapidly (stress test buffer)
   - [ ] Seek during gapless playback
   - [ ] Network interruption during playback

**Success Criteria:**
- ✅ 0ms gaps between tracks (sample-perfect)
- ✅ Track metadata updates precisely
- ✅ No buffer starvation or stuttering
- ✅ All audio formats work

**Phase 3 Checkpoint:** Commit gapless implementation

---

## Rollback Strategy

### If Phase 1 Fails:
```bash
git checkout main
git branch -D feature/bass-modernization
# Document findings in /docs/bass-auto-session-failed.md
```

### If Phase 2 Fails:
```bash
git revert <phase-2-commits>
# Keep Phase 1 changes (they're independent)
```

### If Phase 3 Fails:
```bash
git revert <phase-3-commits>
# Keep Phase 1 & 2 (they're independent)
# Gapless is bonus feature, not critical
```

---

## Success Metrics

### Phase 1 Success:
- Code reduction: 300+ lines removed
- Reliability: "Sometimes works" → "Always works"
- Route changes: No manual intervention needed

### Phase 2 Success:
- BASS version: Latest from un4seen.com
- Compatibility: All Phase 1 tests pass

### Phase 3 Success:
- Gap duration: 0ms (sample-perfect)
- Buffer health: No starvation, optimal levels
- Industry parity: Matches squeezelite quality

---

## Timeline Estimate

| Phase | Estimated Time | Dependencies |
|-------|---------------|--------------|
| Phase 1 | 1-2 days | None |
| Phase 2 | 1 day | Phase 1 complete |
| Phase 3 | 3-5 days | Phase 1 & 2 complete |
| **Total** | **5-8 days** | Sequential |

---

## Risk Assessment

### Phase 1 Risks:
- **Medium:** BASS might not handle sessions as expected
- **Mitigation:** Easy rollback, test incrementally

### Phase 2 Risks:
- **Low:** BASS upgrade might have breaking changes
- **Mitigation:** Keep old version as fallback

### Phase 3 Risks:
- **High:** Complex buffer management, new architecture
- **Mitigation:** Can keep URL streams for fallback, gapless is optional

---

## Current Status

- [x] Roadmap documented
- [ ] Branch created
- [ ] Phase 1 started
- [ ] Phase 2 started
- [ ] Phase 3 started

**Next Step:** Create branch and begin Phase 1 Step 1.1

---

**Last Updated:** 2025-01-16
**Document Version:** 1.0
