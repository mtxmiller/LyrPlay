# Playlist End Detection - Option 4: waitingForNextTrack with Original isStreamActive Behavior

## Problem Statement

Need to detect when playlist ends to send STMu (underrun) to Material UI, but without breaking normal track transitions.

**Previous attempts:**
1. **Minimal approach** (checking `!isStreamActive` in handleStatusRequest): Broke track transitions because any delay between tracks would trigger STMu
2. **Complex approach** (kept `isStreamActive = true` during transitions): May have broken track transitions by changing when `isStreamActive` gets set to false

## Option 4: Best of Both Worlds

Use `waitingForNextTrack` flag to explicitly detect playlist end, BUT keep the original `isStreamActive` behavior unchanged.

### Key Principles

1. **Don't change `isStreamActive` behavior** - It gets set to `false` immediately when track ends (original behavior)
2. **Add `waitingForNextTrack` flag** - Explicitly tracks the window between STMd and server response
3. **Detect playlist end** - If status request comes while `waitingForNextTrack == true`, playlist ended

### Implementation

#### 1. Add Flag (SlimProtoCommandHandler.swift)

```swift
class SlimProtoCommandHandler: ObservableObject {
    // ... existing properties ...

    private var waitingForNextTrack = false  // True after STMd sent, waiting for server's response

    // ...
}
```

#### 2. Set Flag When Track Ends

```swift
func notifyTrackEnded() {
    // CRITICAL: Don't send track end signals during manual skips
    if isManualSkipInProgress {
        os_log(.info, log: logger, "🛡️ Track end blocked - manual skip in progress")
        return
    }

    os_log(.info, log: logger, "🎵 Track ended - sending STMd (decoder ready) to server")

    // KEEP ORIGINAL BEHAVIOR: Reset all tracking state first
    isStreamActive = false  // ← UNCHANGED from original
    isStreamPaused = false
    isPausedByLockScreen = false
    lastKnownPosition = 0.0
    serverStartTime = nil
    serverStartPosition = 0.0

    // Send STMd (decoder ready)
    slimProtoClient?.sendStatus("STMd")

    // NEW: Set flag - we're waiting for server to either start next track or send status request
    waitingForNextTrack = true

    os_log(.info, log: logger, "✅ STMd sent - waiting for server response")
}
```

#### 3. Detect Playlist End in Status Request Handler

```swift
private func handleStatusRequest(_ payload: Data) {
    // Extract server timestamp from strm 't' command
    var serverTimestamp: UInt32 = 0

    if payload.count >= 24 {
        let timestampBytes = payload.subdata(in: 20..<24)
        serverTimestamp = timestampBytes.withUnsafeBytes { bytes in
            bytes.load(as: UInt32.self).bigEndian
        }
    }

    // CRITICAL: If we're waiting for next track and server sends status request, playlist has ended
    if waitingForNextTrack {
        os_log(.info, log: logger, "🛑 End of playlist detected - server sent status request instead of new track")
        waitingForNextTrack = false

        // Send STMu (underrun - natural track end) instead of STMf (forced stop)
        // This tells Material the track finished naturally, not that user stopped it
        slimProtoClient?.sendStatus("STMu", serverTimestamp: serverTimestamp)
        os_log(.info, log: logger, "📍 Sent STMu (underrun) - playlist finished naturally")

        // Stop timers and update UI
        delegate?.didStopStream()
        return
    }

    // Normal status request handling for active streams
    delegate?.didReceiveStatusRequest()

    if isPausedByLockScreen {
        slimProtoClient?.sendStatus("STMp", serverTimestamp: serverTimestamp)
        os_log(.info, log: logger, "📍 Responding to status request with PAUSE status")
    } else {
        slimProtoClient?.sendStatus("STMt", serverTimestamp: serverTimestamp)
        os_log(.info, log: logger, "📍 Responding to status request with TIMER status")
    }
}
```

#### 4. Reset Flag When New Track Starts

```swift
private func handleStartCommand(url: String, format: String, startTime: Double, replayGain: Float) {
    os_log(.info, log: logger, "▶️ Starting %{public}s stream from %.2f with replayGain %.4f", format, startTime, replayGain)

    // ... existing debug logs ...

    // Send STMf (flush) first, like squeezelite
    slimProtoClient?.sendStatus("STMf")

    // Update state
    serverStartTime = Date()
    serverStartPosition = startTime
    lastKnownPosition = startTime
    isStreamPaused = false
    isPausedByLockScreen = false
    isStreamActive = true  // ← UNCHANGED from original

    // NEW: Reset flag - new track has started
    waitingForNextTrack = false

    delegate?.didStartStream(url: url, format: format, startTime: startTime, replayGain: replayGain)
}
```

#### 5. Update SlimProtoClient for STMu Buffer Handling

```swift
// In sendStatus() method:

let bufferFullness: UInt32 = (code == "STMp" || code == "STMu") ? 0 : bufferSize / 2

// ... later in same method ...

let outputBufferFullness: UInt32 = (code == "STMp" || code == "STMu") ? 0 : 4096
```

## How It Works

### Normal Track Transition Flow

1. Track ends → `notifyTrackEnded()` called
2. Sets `isStreamActive = false` (original behavior)
3. Sets `waitingForNextTrack = true`
4. Sends STMd to server
5. **Server immediately sends new track** with strm 's' command
6. `handleStartCommand()` called
7. Sets `waitingForNextTrack = false`
8. Sets `isStreamActive = true`
9. **No status request happens** during this brief window
10. ✅ Track transition works normally

### End of Playlist Flow

1. Track ends → `notifyTrackEnded()` called
2. Sets `isStreamActive = false`
3. Sets `waitingForNextTrack = true`
4. Sends STMd to server
5. **Server has no next track** → sends strm 't' (status request) instead
6. `handleStatusRequest()` called
7. Checks `waitingForNextTrack == true` → playlist ended!
8. Sets `waitingForNextTrack = false`
9. Sends **STMu** (underrun) to Material
10. Calls `didStopStream()` to stop timers
11. ✅ Material sees natural end, stops UI updates

## Advantages Over Previous Approaches

1. **No change to `isStreamActive` behavior** - Other code that depends on this flag won't break
2. **Explicit detection** - We know exactly when playlist ended (status request after STMd)
3. **No race conditions** - Flag is set/reset at precise moments
4. **No delays or timers** - Immediate detection
5. **Minimal code changes** - Only adds one flag and a few checks

## Why This Should Work Better

**Previous complex approach (commit 9f9064a) changed:**
- Kept `isStreamActive = true` during track transitions
- This may have broken other code that checks `isStreamActive` (heartbeat, status handling, etc.)

**This approach (Option 4):**
- Keeps `isStreamActive` behavior EXACTLY as original
- Only adds a secondary flag for playlist end detection
- Shouldn't interfere with any existing logic

## Testing Checklist

- [ ] Normal track transitions (track-to-track)
- [ ] End of playlist (Material UI stops, doesn't jump around)
- [ ] Lock screen stops counting at playlist end
- [ ] Manual skip during playback
- [ ] Pause/resume during playback
- [ ] CarPlay connect/disconnect during playback
- [ ] Route changes (AirPods, speakers) during playback
- [ ] App backgrounding during playback
- [ ] Lock screen recovery when disconnected

## Rollback Plan

If this doesn't work, we have two options:

1. **Revert to minimal approach** (current commit e6f7703) - Simple but breaks transitions
2. **Try Option 2 or 3** - Counter-based or delay-based detection

## Files to Modify

1. `LMS_StreamTest/SlimProtoCommandHandler.swift`
   - Add `waitingForNextTrack` flag
   - Modify `notifyTrackEnded()` to set flag
   - Modify `handleStatusRequest()` to check flag
   - Modify `handleStartCommand()` to reset flag

2. `LMS_StreamTest/SlimProtoClient.swift`
   - Add STMu to buffer fullness conditions (already done in e6f7703)
