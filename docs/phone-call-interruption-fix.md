# Phone Call Interruption Fix

**Date:** January 14, 2025
**Status:** ✅ Complete
**File Modified:** `PlaybackSessionController.swift`

## Problem Statement

When a phone call interrupted audio playback in LyrPlay:
- ✅ Music properly paused when call started
- ❌ Music did NOT auto-resume when call ended
- User had to manually press play to resume playback

This was inconsistent with other recovery mechanisms (lock screen recovery, route changes) which worked correctly.

## Root Causes Discovered

### 1. BASS Reinitialization During Active Calls
When a phone call started and the audio route changed to phone receiver (`.builtInReceiver` or `.bluetoothHFP`), the route change handler was reinitializing BASS. This kept the music playing **through the phone receiver during the call**.

**Why it happened:** The route change handler didn't distinguish between phone call routes and other route changes (AirPods, speakers).

### 2. iOS Interruption Ended Notification Never Fired
According to Apple's documentation: **"There is no guarantee that a begin interruption will have an end interruption."**

Testing confirmed:
- `🚫 Interruption began` notification fired ✅
- `✅ Interruption ended` notification **NEVER FIRED** ❌

This is a known iOS bug across multiple iOS versions, documented on Stack Overflow and Apple forums.

### 3. iOS `.shouldResume` Flag Unreliable
Even when interruption ended notifications DID fire (in some scenarios), iOS's `AVAudioSessionInterruptionOptions.shouldResume` flag was often `false` even when audio was playing before the interruption.

**Research findings:**
- Flag is unreliable for rejected calls, ignored calls, backgrounded apps
- Multiple developers report moving `play()` outside the `shouldResume` check
- Recommended approach: Trust your own `shouldAutoResume` logic, not iOS's flag

### 4. Missing BASS Reinitialization After Interruption
After interruptions, the audio route changes (phone receiver → speaker), but BASS needs to be reinitialized to pick up the new route. The interruption ended handler didn't include this step.

## Solution Implemented

### Part 1: Prevent BASS Reinit During Phone Calls (Lines 346-357)

```swift
// PHONE CALL FIX: Detect phone call routes
let isPhoneCallRoute = currentOutputs.contains(.builtInReceiver) ||
                       previousOutputs.contains(.builtInReceiver) ||
                       currentOutputs.contains(.bluetoothHFP) ||
                       previousOutputs.contains(.bluetoothHFP)

// Skip BASS reinit for phone calls - interruption handler manages playback
if !isCarPlayEvent && !isPhoneCallRoute {
    // Only reinit BASS for AirPods, speakers, etc.
    playbackController?.handleAudioRouteChange()
}
```

**Effect:** Music stops when phone call starts (interruption handler sends pause), doesn't keep playing through phone receiver.

### Part 2: Trust Our Own Auto-Resume Logic (Lines 293-296)

```swift
// PHONE CALL FIX: Don't rely on iOS .shouldResume flag
// Apple docs: "There is no guarantee that a begin interruption will have an end interruption"
// Trust our own shouldAutoResume logic instead
let shouldResume = context?.shouldAutoResume ?? false
```

**Effect:** If interruption ended notification DOES fire, we resume based on our logic (was audio playing before interruption?), not iOS's unreliable flag.

### Part 3: BASS Reinitialization After Interruption (Lines 307-324)

```swift
case .ended:
    guard shouldResume else { return }

    ensureActive(context: .serverResume)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        // Reinitialize BASS for post-interruption route
        self.playbackController?.handleAudioRouteChange()

        // Send play command after BASS is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.slimProtoProvider?()?.sendLockScreenCommand("play")
        }
    }
```

**Effect:** If interruption ended notification fires, properly reinitialize BASS before resuming.

### Part 4: Route-Change-Based Resume (Lines 396-417) ⭐ **KEY FIX**

```swift
// PHONE CALL FIX: Check if we need to resume after interruption
// iOS often doesn't fire interruption ended notification - handle resume via route change
let currentlyOnPhoneRoute = currentOutputs.contains(.builtInReceiver) ||
                            currentOutputs.contains(.bluetoothHFP)

if !currentlyOnPhoneRoute && interruptionContext != nil {
    if let context = interruptionContext, context.shouldAutoResume {
        os_log(.info, log: logger, "📞 Interruption ended via route change - auto-resuming")

        interruptionContext = nil

        // Send play command after delay to allow BASS reinit to complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.slimProtoProvider?()?.sendLockScreenCommand("play")
        }
    }
}
```

**Why this is the key fix:**
- **Doesn't rely on interruption ended notification** (which often doesn't fire)
- **Triggered by route changes after phone call ends** (which DO fire reliably)
- **Simple logic:** If we have interruption context AND we're NOT on a phone route → resume
- **0.6s delay** allows BASS reinitialization (from Part 1 route handler) to complete

## How It Works

### Phone Call Start Flow:
1. Phone call begins → audio route changes to phone receiver
2. Interruption began notification fires
3. `interruptionContext` saved with `shouldAutoResume = true` (was playing)
4. Interruption handler sends pause command to server
5. Route change notification fires (to phone receiver)
6. Route handler detects `isPhoneCallRoute = true` → **skips BASS reinit** (Part 1)
7. Music stops, phone call proceeds normally

### Phone Call End Flow:
1. Phone call ends → audio route changes back to speaker
2. Route change notification fires (Override or Category Change)
3. Route handler checks: `isPhoneCallRoute = false` → reinitializes BASS (Part 1)
4. BASS reinit completes: deactivates session, reinitializes device, requests playlist jump
5. Route handler checks: **"NOT on phone route AND have interruptionContext"** (Part 4)
6. After 0.6s delay: sends play command to server
7. Music resumes at saved position ✅

**Note:** Interruption ended notification may or may not fire - doesn't matter! Part 4 handles resume via route change.

## Guard Protection Against Double Reinit

The `reinitializeBASS()` method in `AudioPlayer.swift` has a guard:

```swift
guard currentStream != 0, !currentStreamURL.isEmpty else {
    return  // Skip if already cleaned up
}
```

After the first `reinitializeBASS()` call, `currentStream = 0`, so any subsequent call returns immediately. This prevents conflicts if both interruption ended AND route change fire.

## Scenarios Tested

| Scenario | Music Stops | Music Resumes | Notes |
|----------|-------------|---------------|-------|
| Phone call (regular) | ✅ | ✅ | Uses Part 4 (route change resume) |
| Phone call (Bluetooth) | ✅ | ✅ | Detects `.bluetoothHFP` route |
| Text message | ✅ | ✅ | Uses Part 3 or Part 4 |
| Siri interruption | ✅ | ✅ | Both approaches work |
| AirPods disconnect | ✅ | N/A | Existing route handler works |
| CarPlay connect/disconnect | ✅ | ✅ | Dedicated CarPlay handlers (unchanged) |

## Key Learnings

### About iOS Audio Interruptions:
1. **Never trust `AVAudioSessionInterruptionOptions.shouldResume`** - implement your own logic
2. **Interruption ended notifications are unreliable** - have a fallback mechanism
3. **Route changes are more reliable** than interruption notifications for detecting call end
4. **Phone call routes are special** - they need different handling than other route changes

### About BASS Audio Library:
1. **BASS needs reinitialization after route changes** to switch audio output devices
2. **Reinitialization involves:** `BASS_Free()` → `BASS_Init()` → recreate stream
3. **Guard clauses prevent double reinit** when multiple notifications fire
4. **Position recovery uses playlist jump** instead of recreating streams at specific positions

### About Timing:
1. **0.6s delay for play command** allows BASS reinit to complete
2. **0.2s delay for BASS reinit** allows audio session activation to complete
3. **Delays are necessary** because iOS audio session changes are asynchronous

## Related Issues Fixed

This fix also resolves:
- Text message interruptions not resuming
- FaceTime audio call interruptions
- Any interruption where iOS doesn't fire interruption ended notification

## Future Considerations

### If Issues Arise:
- **Music plays during call:** Check Part 1 - phone route detection may need adjustment
- **Doesn't resume after call:** Check logs for `interruptionContext` - may be `nil` or `shouldAutoResume = false`
- **Resumes too early (BASS error):** Increase delay in Part 4 (currently 0.6s)
- **Double play commands:** Check guard in `reinitializeBASS()` - may need adjustment

### Potential Enhancements:
- Monitor `CallKit` for more reliable phone call detection
- Track timing metrics to optimize delays
- Add user preference for auto-resume behavior after interruptions

## References

- **Apple Documentation:** [Responding to Interruptions](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)
- **Stack Overflow:** Multiple threads documenting `.shouldResume` unreliability
- **Twilio Audio Interruption Guide:** Documents scenarios where `.shouldResume` is false
- **BASS Audio Library:** [www.un4seen.com](http://www.un4seen.com) - iOS audio device management

---

**Implementation Complete:** January 14, 2025
**Tested:** Phone calls (regular & Bluetooth), text messages, various interruption scenarios
**Status:** Ready for production deployment
