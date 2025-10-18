# Proposal: Full BASS iOS Audio Session Management

## Executive Summary

**Goal:** Remove all manual `AVAudioSession` management and let BASS library handle iOS audio session completely (Ian's Option 1 from forum).

**Expected Benefits:**
- ✅ Eliminate timing race conditions on route changes
- ✅ Fix "sometimes works, sometimes doesn't" bugs
- ✅ Remove ~300 lines of complex session management code
- ✅ More reliable CarPlay/AirPods/phone call handling
- ✅ Industry-standard approach (like Spotify, Apple Music)

**Risks:**
- ⚠️ Lock screen controls might need adjustment
- ⚠️ Interruption handling might need tweaking
- ⚠️ Unknown edge cases with SlimProto protocol

**Reversibility:** Easy - just revert the commit if it doesn't work

---

## Background: Forum Post Analysis

From BASS iOS Audio Route Change Issue forum post (Ian @ un4seen):

> "When you're handling audio session management yourself, you should set BASS_CONFIG_IOS_SESSION to **BASS_IOS_SESSION_DISABLE** rather than **0**."

**Ian's recommended progression:**

1. **Option 1**: `0` (default) WITHOUT manual management → Let BASS do everything
2. **Option 2**: `BASS_IOS_SESSION_DEACTIVATE` (32) → BASS manages but deactivates when idle
3. **Option 3**: `BASS_IOS_SESSION_DISABLE` (16) WITH manual management → Full manual control

**Our current BROKEN setup:**
- Using `0` (which means "BASS manages")
- BUT also manually managing AVAudioSession
- Result: They fight each other → intermittent bugs

---

## Changes Required

### 1. AudioPlayer.swift

#### REMOVE: Manual BASS session configuration
```swift
// DELETE lines 68-72:
// BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), DWORD(BASS_IOS_SESSION_DISABLE))

// REPLACE WITH: Nothing! Default = BASS manages
```

#### REMOVE: Manual session setup
```swift
// DELETE setupManualAudioSession() - line 127-129
// DELETE configureAudioSessionIfNeeded() - line 132-134
```

#### REMOVE: Entire reinitializeBASS() function
```swift
// DELETE lines 118-125 (entire function)
func reinitializeBASS() {
    // DELETE ALL OF THIS - BASS handles route changes automatically
}

// REPLACE handleAudioRouteChange() with simple logging:
func handleAudioRouteChange() {
    os_log(.info, log: logger, "🔀 Route changed - BASS handling automatically")
    // No action needed - BASS switches routes automatically
}
```

**Full changes for AudioPlayer.swift:**

```swift
// MARK: - Core Setup (MINIMAL CBASS)
private func setupCBass() {
    // BASS handles iOS audio session automatically with default settings
    // No BASS_SetConfig(BASS_CONFIG_IOS_SESSION, ...) needed

    // Minimal BASS initialization - keep it simple
    let result = BASS_Init(-1, 44100, 0, nil, nil)

    if result == 0 {
        let errorCode = BASS_ErrorGetCode()
        os_log(.error, log: logger, "❌ BASS initialization failed: %d", errorCode)
        return
    }

    let verifyBytes = DWORD(1024 * 1024)
    BASS_SetConfig(DWORD(BASS_CONFIG_VERIFY), verifyBytes)
    BASS_SetConfig(DWORD(BASS_CONFIG_VERIFY_NET), verifyBytes)
    os_log(.info, log: logger, "🔍 BASS verification window increased to %u bytes", verifyBytes)

    // Enable ICY metadata for radio streams
    BASS_SetConfig(DWORD(BASS_CONFIG_NET_META), 1)

    os_log(.info, log: logger, "✅ BASS configured with automatic iOS session management")
    os_log(.info, log: logger, "✅ CBass configured - Version: %08X", BASS_GetVersion())
}

// MARK: - Route Change Handling (Simplified)
/// BASS handles route changes automatically - no reinit needed
func handleAudioRouteChange() {
    os_log(.info, log: logger, "🔀 Audio route changed - BASS handling automatically")
    // BASS automatically switches audio device
    // We just log for debugging - no action needed
}
```

---

### 2. PlaybackSessionController.swift

#### REMOVE: Manual session activation/deactivation
```swift
// DELETE ensureActive() function - lines 137-154
// DELETE deactivateIfNeeded() function - lines 156-167

// REPLACE calls to ensureActive() with nothing or just logging
```

#### SIMPLIFY: Route change handler
```swift
@objc private func handleRouteChange(_ notification: Notification) {
    guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
        return
    }

    let previousRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
    let previousHadCarPlay = previousRoute?.outputs.contains(where: { $0.portType == .carAudio }) ?? false
    let currentHasCarPlay = audioSession.currentOutputs.contains(.carAudio)

    os_log(.info, log: logger, "🔀 Route change (%{public}s) carPlayPrev=%{public}s carPlayNow=%{public}s",
           describe(reason: reason), previousHadCarPlay ? "YES" : "NO", currentHasCarPlay ? "YES" : "NO")

    // Determine if this is a CarPlay event
    let isCarPlayEvent = (currentHasCarPlay && !isCarPlayActive) || (!currentHasCarPlay && (isCarPlayActive || previousHadCarPlay))

    // PHONE CALL FIX v2: Distinguish between ENTERING and EXITING phone call routes
    let currentOutputs = audioSession.currentOutputs
    let previousOutputs = previousRoute?.outputs.map { $0.portType } ?? []

    let currentHasPhoneRoute = currentOutputs.contains(.builtInReceiver) || currentOutputs.contains(.bluetoothHFP)
    let previousHadPhoneRoute = previousOutputs.contains(.builtInReceiver) || previousOutputs.contains(.bluetoothHFP)

    os_log(.info, log: logger, "🔀 Phone call state: current=%{public}s, previous=%{public}s",
           currentHasPhoneRoute ? "YES" : "NO",
           previousHadPhoneRoute ? "YES" : "NO")

    // REMOVED: All BASS reinit logic - BASS handles route changes automatically
    // Log if this was exiting a phone call
    if previousHadPhoneRoute && !currentHasPhoneRoute {
        os_log(.info, log: logger, "📞 Exited phone call route - BASS handling automatically")
    }

    // PHONE CALL FIX: Check if we need to resume after interruption (phone call, etc.)
    // iOS often doesn't fire interruption ended notification - handle resume via route change
    if !currentHasPhoneRoute && interruptionContext != nil {
        if let context = interruptionContext, context.shouldAutoResume {
            os_log(.info, log: logger, "📞 Interruption ended via route change - auto-resuming")

            // Clear interruption context - we're handling it now
            interruptionContext = nil

            // Send play command to server
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.slimProtoProvider?()?.sendLockScreenCommand("play")
                os_log(.info, log: self?.logger ?? OSLog.default, "📞 Sent play command after interruption ended")
            }
        } else {
            os_log(.info, log: logger, "📞 Interruption ended but shouldNotResume")
            interruptionContext = nil
        }
    }

    // Handle CarPlay connect/disconnect (simplified)
    if currentHasCarPlay && !isCarPlayActive {
        isCarPlayActive = true
        handleCarPlayConnected()
    } else if !currentHasCarPlay && (isCarPlayActive || previousHadCarPlay) {
        isCarPlayActive = false
        handleCarPlayDisconnected()
    }

    // Handle AirPods/headphone disconnection (send pause command only)
    if reason == .oldDeviceUnavailable && !previousHadCarPlay {
        let wasPlaying = playbackController?.isPlaying ?? false
        if wasPlaying {
            os_log(.info, log: logger, "🎧 AirPods/headphones disconnected - pausing server")
            slimProtoProvider?()?.sendLockScreenCommand("pause")
        }
    }
}
```

#### SIMPLIFY: Interruption handler
```swift
@objc private func handleInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue) else {
        return
    }

    switch interruptionType {
    case .began:
        let interruptionKind = determineInterruptionType(userInfo: userInfo)
        let wasPlaying = playbackController?.isPlaying ?? false
        let shouldResume = shouldAutoResume(after: interruptionKind, wasPlaying: wasPlaying)
        interruptionContext = InterruptionContext(type: interruptionKind,
                                                  beganAt: Date(),
                                                  shouldAutoResume: shouldResume,
                                                  wasPlaying: wasPlaying)

        os_log(.info, log: logger, "🚫 Interruption began (%{public}s, autoResume=%{public}s)",
               interruptionKind.rawValue, shouldResume ? "YES" : "NO")
        if wasPlaying {
            // Send server pause command
            // BASS handles audio session pause automatically
            slimProtoProvider?()?.sendLockScreenCommand("pause")
            os_log(.info, log: logger, "📡 Sent server pause command for interruption")
        }

    case .ended:
        let context = interruptionContext
        let shouldResume = context?.shouldAutoResume ?? false

        os_log(.info, log: logger, "✅ Interruption ended (%{public}s, app.shouldResume=%{public}s)",
               context?.type.rawValue ?? InterruptionType.unknown.rawValue,
               shouldResume ? "YES" : "NO")

        interruptionContext = nil

        guard shouldResume else { return }

        // REMOVED: Manual session activation and BASS reinit
        // BASS handles audio session resume automatically

        // Just send play command to server after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.slimProtoProvider?()?.sendLockScreenCommand("play")
            os_log(.info, log: self?.logger ?? OSLog.default, "📡 Sent server play command for interruption resume")
        }

    @unknown default:
        break
    }
}
```

#### SIMPLIFY: CarPlay handlers
```swift
private func handleCarPlayConnected() {
    guard !shouldThrottleCarPlayEvent() else { return }
    refreshRemoteCommandCenter()
    endBackgroundTask()
    os_log(.info, log: logger, "🚗 CarPlay connected - BASS handling route automatically")

    // REMOVED: Manual session deactivate/reactivate/BASS reinit
    // BASS automatically switches to CarPlay audio

    wasPlayingBeforeCarPlayDetach = false
}

private func handleCarPlayDisconnected() {
    guard !shouldThrottleCarPlayEvent() else { return }
    os_log(.info, log: logger, "🚗 CarPlay disconnected - pausing playback")
    wasPlayingBeforeCarPlayDetach = playbackController?.isPlaying ?? false
    beginBackgroundTask(named: "CarPlayDisconnect")

    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }

        // REMOVED: Manual session deactivate/reactivate/BASS reinit
        // BASS automatically switches from CarPlay to speaker

        // Just send pause command to server
        if let coordinator = self.slimProtoProvider?() {
            coordinator.sendLockScreenCommand("pause")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.endBackgroundTask()
        }
    }
}
```

---

### 3. What We KEEP

#### ✅ Keep All SlimProto Communication
```swift
// Keep all server command sending
slimProtoProvider?()?.sendLockScreenCommand("play")
slimProtoProvider?()?.sendLockScreenCommand("pause")
coordinator.requestSeekToTime(position)
coordinator.performPlaylistRecovery()
```

#### ✅ Keep Position Recovery
```swift
// Keep position saving/recovery for disconnection scenarios
coordinator.saveCurrentPositionForRecovery()
coordinator.performPlaylistRecovery()
```

#### ✅ Keep Lock Screen Integration
```swift
// Keep MPNowPlayingInfoCenter
MPNowPlayingInfoCenter.default().nowPlayingInfo = [...]

// Keep MPRemoteCommandCenter
MPRemoteCommandCenter.shared().playCommand.addTarget { ... }
```

#### ✅ Keep Notification Observers
```swift
// Keep listening to these (for logging and SlimProto commands)
AVAudioSession.interruptionNotification
AVAudioSession.routeChangeNotification
AVAudioSession.mediaServicesWereResetNotification
```

---

## What We Remove (Summary)

### From AudioPlayer.swift:
- ❌ `BASS_SetConfig(BASS_CONFIG_IOS_SESSION, ...)` calls (2 places)
- ❌ `setupManualAudioSession()` function
- ❌ `configureAudioSessionIfNeeded()` function
- ❌ `reinitializeBASS()` function (entire ~50 lines)
- ❌ All `BASS_Free()` → `BASS_Init()` cycles

### From PlaybackSessionController.swift:
- ❌ `ensureActive()` function
- ❌ `deactivateIfNeeded()` function
- ❌ All `AVAudioSession.setActive()` calls
- ❌ All `BASS reinit` calls
- ❌ All timing delays (0.3s, 0.5s waits)
- ❌ Route change → BASS reinit logic
- ❌ CarPlay connect/disconnect session management

**Total lines removed: ~300-400 lines**

---

## Expected Behavior After Changes

### Route Changes (AirPods, CarPlay, Speakers)
**Before:**
1. iOS fires route change notification
2. We deactivate AVAudioSession
3. Wait 0.3s for iOS to settle
4. Reactivate AVAudioSession
5. BASS_Free() old device
6. BASS_Init() new device
7. Request new stream from server
8. **Sometimes works, sometimes doesn't** (timing race)

**After:**
1. iOS fires route change notification
2. BASS automatically switches audio device
3. We log it for debugging
4. **Always works** (BASS handles timing)

### Phone Calls
**Before:**
1. Call starts → We skip BASS reinit (entering call)
2. Call ends → We DO BASS reinit (exiting call)
3. **Sometimes fails** with AirPods (HFP→A2DP timing)

**After:**
1. Call starts → BASS automatically switches to HFP
2. Call ends → BASS automatically switches back to A2DP
3. We just send pause/play commands to server
4. **Always works** (BASS handles profile switching)

### Interruptions (Siri, Alarms)
**Before:**
1. Interruption → Manually pause and deactivate session
2. Interruption ends → Manually reactivate session, reinit BASS, resume
3. **Complex timing-sensitive logic**

**After:**
1. Interruption → BASS automatically pauses
2. Interruption ends → BASS automatically resumes
3. We just send pause/play commands to server
4. **Simple and reliable**

---

## Testing Plan

### Phase 1: Basic Functionality
- [ ] App starts and plays music
- [ ] Lock screen controls work (play/pause/next/prev)
- [ ] Metadata shows on lock screen
- [ ] Position tracking works

### Phase 2: Route Changes
- [ ] Connect/disconnect AirPods while playing
- [ ] Connect/disconnect wired headphones
- [ ] Switch speaker → AirPods → speaker
- [ ] CarPlay connect/disconnect

### Phase 3: Interruptions
- [ ] Phone call (speaker)
- [ ] Phone call (AirPods)
- [ ] Siri text message notification
- [ ] Timer/alarm
- [ ] Other app plays audio

### Phase 4: Edge Cases
- [ ] Background/foreground app
- [ ] Rapid route changes
- [ ] Multiple interruptions in sequence
- [ ] Network disconnect during route change

---

## Rollback Plan

If testing reveals issues:

1. **Simple rollback:**
   ```bash
   git revert <commit-hash>
   ```

2. **Hybrid fallback:**
   - Keep simplified interruption handlers
   - Re-add only BASS reinit on route changes
   - Use `BASS_IOS_SESSION_DISABLE` (16) properly

3. **Emergency:**
   - Revert to previous working commit
   - File issue with detailed logs

---

## Risk Assessment

### Low Risk:
- ✅ Easy to revert (single commit)
- ✅ Industry-standard approach (Spotify, Apple Music do this)
- ✅ Recommended by BASS library creator (Ian)
- ✅ Simpler code = fewer bugs

### Medium Risk:
- ⚠️ Unknown SlimProto edge cases
- ⚠️ Might need tweaks to lock screen command timing
- ⚠️ Could reveal bugs in BASS library (unlikely)

### Mitigation:
- Test thoroughly before committing
- Keep detailed logs during testing
- Document any issues found
- Easy rollback available

---

## Implementation Steps

1. **Create feature branch:**
   ```bash
   git checkout -b feature/bass-auto-session
   ```

2. **Make changes** (as detailed above)

3. **Test extensively** (all scenarios above)

4. **Commit if successful:**
   ```bash
   git add .
   git commit -m "Let BASS manage iOS audio session automatically"
   ```

5. **If issues found:**
   ```bash
   git checkout main
   git branch -D feature/bass-auto-session
   ```

---

## Code Diff Preview

**AudioPlayer.swift** (~50 lines removed):
```diff
- BASS_SetConfig(DWORD(BASS_CONFIG_IOS_SESSION), DWORD(BASS_IOS_SESSION_DISABLE))
+ // BASS manages iOS session automatically (default behavior)

- func reinitializeBASS() {
-     // 50 lines of complex reinit logic
- }
+ func handleAudioRouteChange() {
+     os_log("🔀 Route changed - BASS handling automatically")
+ }
```

**PlaybackSessionController.swift** (~250 lines removed/simplified):
```diff
- func ensureActive(context: ActivationContext) {
-     // Manual AVAudioSession activation
- }

- func deactivateIfNeeded() {
-     // Manual AVAudioSession deactivation
- }

  func handleRouteChange() {
-     try audioSession.setActive(false)
-     wait(0.3s)
-     ensureActive()
-     playbackController?.handleAudioRouteChange() // BASS reinit
+     os_log("🔀 Route changed - BASS handling")
+     // Just send SlimProto commands if needed
  }
```

---

## Comparison: Normal Audio Apps vs LyrPlay

| Feature | Normal Apps (BASS manages) | LyrPlay (Manual - current) |
|---------|---------------------------|----------------------------|
| **Code complexity** | Simple - 5 lines | Complex - 200+ lines of session management |
| **Route changes** | Automatic | Manual reinit dance (buggy) |
| **Interruptions** | Automatic | Manual pause/resume/reinit (buggy) |
| **Lock screen** | Works | Works (but complicated) |
| **CarPlay** | Automatic routing | Manual routing (buggy) |
| **Timing issues** | None (BASS handles) | Many (we handle) |
| **Bugs** | Rare | "Sometimes works, sometimes doesn't" |
| **Lines of code** | ~50 | ~500 |

---

## Recommendation

**This approach is recommended** because:

1. **Fixes root cause** - Manual management + wrong constant = conflicts
2. **Industry standard** - How all major iOS audio apps work
3. **Creator approved** - Ian@un4seen specifically recommends this
4. **Simpler code** - 300 fewer lines = fewer bugs
5. **Easy rollback** - Single commit revert if needed

---

**Status:** Plan documented for future implementation
**Date Created:** 2025-01-16
**Related Issues:**
- Phone call interruption bugs with AirPods
- "Sometimes works, sometimes doesn't" route change issues
- BASS_CONFIG_IOS_SESSION misconfiguration (0 vs 16)
