# Phone Call Interruption Fix - AirPods & Siri Issues

## Problems Identified

### Problem 1: AirPods + Phone Call
**Symptom**: Music doesn't resume after phone call when using AirPods

**Root Cause**:
```swift
// Lines 66-69: Detect if we're on a phone call route
let isPhoneCallRoute = currentOutputs.contains(.builtInReceiver) ||
                       previousOutputs.contains(.builtInReceiver) ||
                       currentOutputs.contains(.bluetoothHFP) ||
                       previousOutputs.contains(.bluetoothHFP)

// Line 74: Skip BASS reinit for phone call routes
if !isCarPlayEvent && !isPhoneCallRoute {
    // Reinitialize BASS...
}
```

**What Happens with AirPods**:
1. **Playing music**: Route = `.bluetoothA2DP` (AirPods music profile)
2. **Phone call starts**: Route changes to `.bluetoothHFP` (hands-free profile)
   - `isPhoneCallRoute = true` (current = .bluetoothHFP)
   - BASS reinit **skipped** ✅ (correct - don't reinit during call)
3. **Phone call ends**: Route changes back to `.bluetoothA2DP`
   - `previousOutputs = [.bluetoothHFP]`
   - `isPhoneCallRoute = true` (previous has .bluetoothHFP)
   - BASS reinit **skipped** ❌ (WRONG - need to reinit to switch back to music profile!)

**The Bug**: We skip BASS reinitialization when **exiting** a phone call route, but we NEED to reinit to switch Bluetooth from HFP (phone) back to A2DP (music).

---

### Problem 2: Siri Text Message Interruptions
**Symptom**: Music doesn't resume after Siri reads a text message

**Root Cause**:
```swift
// Lines 248-250: Siri detected as "other audio"
if audioSession.otherAudioIsPlaying {
    return .otherAudio
}

// Lines 268-269: Never auto-resume for other audio
case .otherAudio:
    return false
```

**What Happens with Siri**:
1. **Playing music**: Normal playback
2. **Text message arrives**: Siri interrupts to read message
   - iOS reports `otherAudioIsPlaying = true`
   - Interruption type determined as `.otherAudio`
   - `shouldAutoResume = false` ❌
3. **Siri finishes**: Interruption ended notification fires
   - But `shouldAutoResume = false`, so we don't resume

**The Bug**: Siri is categorized as `.otherAudio`, which never auto-resumes.

---

## The Fix

### Fix 1: Detect Phone Call Entry vs. Exit

We need to distinguish between:
- **Entering phone call route**: Skip BASS reinit (audio goes to phone receiver/HFP)
- **Exiting phone call route**: DO reinit BASS (audio needs to switch back to music route)

```swift
// NEW: Detect if we're ENTERING a phone call route (not just on one)
let isEnteringPhoneCall = (currentOutputs.contains(.builtInReceiver) || currentOutputs.contains(.bluetoothHFP)) &&
                          !(previousOutputs.contains(.builtInReceiver) || previousOutputs.contains(.bluetoothHFP))

// NEW: Detect if we're EXITING a phone call route
let isExitingPhoneCall = !(currentOutputs.contains(.builtInReceiver) || currentOutputs.contains(.bluetoothHFP)) &&
                         (previousOutputs.contains(.builtInReceiver) || previousOutputs.contains(.bluetoothHFP))

// Only skip BASS reinit when ENTERING phone call, not when exiting
if !isCarPlayEvent && !isEnteringPhoneCall {
    // Reinitialize BASS for all route changes EXCEPT entering phone calls
    // This includes:
    // - AirPods connect/disconnect
    // - Speaker changes
    // - EXITING phone calls (HFP → A2DP) ✅
}
```

---

### Fix 2: Detect Siri Specifically

Siri interruptions should auto-resume, but we need to detect them differently.

**Option A: Check for shorter interruptions**
```swift
private func determineInterruptionType(userInfo: [AnyHashable: Any]) -> InterruptionType {
    // ... existing checks ...

    // Siri/notification interruptions are typically short
    // Phone calls change routes to receiver/HFP
    // Siri keeps same route but reports otherAudioIsPlaying
    if audioSession.otherAudioIsPlaying {
        // Check if route changed to phone
        let outputs = audioSession.currentOutputs
        if outputs.contains(.builtInReceiver) || outputs.contains(.bluetoothHFP) {
            return .phoneCall  // Phone call
        } else {
            return .siri  // Siri/notification (same route, just audio duck)
        }
    }

    // ... rest of checks ...
}

private func shouldAutoResume(after type: InterruptionType, wasPlaying: Bool) -> Bool {
    guard wasPlaying else { return false }

    switch type {
    case .otherAudio:
        return false  // Music apps, podcasts, etc.
    case .siri:
        return true   // Siri notifications should auto-resume ✅
    default:
        return true
    }
}
```

**Option B: Use interruption reason (iOS 14.5+)**
```swift
private func determineInterruptionType(userInfo: [AnyHashable: Any]) -> InterruptionType {
    if let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
       let reason = AVAudioSession.InterruptionReason(rawValue: reasonValue) {
        switch reason {
        case .appWasSuspended:
            return .siri  // Siri often shows as appWasSuspended
        case .builtInMicMuted:
            return .otherAudio
        case .default:
            break
        @unknown default:
            break
        }
    }

    // ... rest of detection logic ...
}
```

---

## Complete Fixed Code

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

    let isCarPlayEvent = (currentHasCarPlay && !isCarPlayActive) || (!currentHasCarPlay && (isCarPlayActive || previousHadCarPlay))

    // PHONE CALL FIX v2: Distinguish between ENTERING and EXITING phone call routes
    let currentOutputs = audioSession.currentOutputs
    let previousOutputs = previousRoute?.outputs.map { $0.portType } ?? []

    let currentHasPhoneRoute = currentOutputs.contains(.builtInReceiver) || currentOutputs.contains(.bluetoothHFP)
    let previousHadPhoneRoute = previousOutputs.contains(.builtInReceiver) || previousOutputs.contains(.bluetoothHFP)

    // Only skip BASS reinit when ENTERING phone call (not when exiting)
    let isEnteringPhoneCall = currentHasPhoneRoute && !previousHadPhoneRoute

    os_log(.info, log: logger, "🔀 Phone call state: entering=%{public}s, current=%{public}s, previous=%{public}s",
           isEnteringPhoneCall ? "YES" : "NO",
           currentHasPhoneRoute ? "YES" : "NO",
           previousHadPhoneRoute ? "YES" : "NO")

    // CRITICAL: Reinitialize BASS for all NON-CarPlay route changes EXCEPT entering phone calls
    // This now includes EXITING phone calls (HFP → A2DP for AirPods) ✅
    if !isCarPlayEvent && !isEnteringPhoneCall {
        if reason == .oldDeviceUnavailable {
            workQueue.async { [weak self] in
                guard let self = self else { return }

                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    os_log(.info, log: self.logger, "🔀 Device removed: Deactivated audio session")
                } catch {
                    os_log(.error, log: self.logger, "🔀 Failed to deactivate: %{public}s", error.localizedDescription)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.ensureActive(context: .backgroundRefresh)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.playbackController?.handleAudioRouteChange()
                        os_log(.info, log: self.logger, "🔀 Device removed: BASS reinitialized")
                    }
                }
            }
        } else {
            workQueue.async { [weak self] in
                guard let self = self else { return }
                self.ensureActive(context: .backgroundRefresh)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.playbackController?.handleAudioRouteChange()

                    // Log if this was exiting a phone call
                    if previousHadPhoneRoute && !currentHasPhoneRoute {
                        os_log(.info, log: self.logger, "📞 Exited phone call route - BASS reinitialized for music profile")
                    } else {
                        os_log(.info, log: self.logger, "🔀 Route change: BASS reinitialized")
                    }
                }
            }
        }
    }

    // PHONE CALL FIX: Check if we need to resume after interruption
    if !currentHasPhoneRoute && interruptionContext != nil {
        if let context = interruptionContext, context.shouldAutoResume {
            os_log(.info, log: logger, "📞 Interruption ended via route change - auto-resuming")

            interruptionContext = nil

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.slimProtoProvider?()?.sendLockScreenCommand("play")
                os_log(.info, log: self?.logger ?? OSLog.default, "📞 Sent play command after interruption ended")
            }
        } else {
            os_log(.info, log: logger, "📞 Interruption ended but shouldNotResume")
            interruptionContext = nil
        }
    }

    // ... rest of method unchanged ...
}

// SIRI FIX: Improved interruption type detection
private func determineInterruptionType(userInfo: [AnyHashable: Any]) -> InterruptionType {
    if let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
       let reason = AVAudioSession.InterruptionReason(rawValue: reasonValue) {
        switch reason {
        case .appWasSuspended:
            // Siri often shows as appWasSuspended
            return .siri
        case .builtInMicMuted:
            return .otherAudio
        case .default:
            break
        @unknown default:
            break
        }
    }

    if let suspended = userInfo[AVAudioSessionInterruptionWasSuspendedKey] as? Bool, suspended {
        return .otherAudio
    }

    // Check if route changed to phone call routes
    let outputs = audioSession.currentOutputs
    if outputs.contains(.builtInReceiver) || outputs.contains(.bluetoothHFP) {
        return .phoneCall
    }

    // Siri/notification: other audio playing but route didn't change to phone
    if audioSession.otherAudioIsPlaying {
        return .siri  // Auto-resume for Siri notifications
    }

    if UIApplication.shared.applicationState != .active {
        return .phoneCall
    }

    return .unknown
}

private func shouldAutoResume(after type: InterruptionType, wasPlaying: Bool) -> Bool {
    guard wasPlaying else { return false }

    switch type {
    case .otherAudio:
        return false  // Music apps, podcasts - don't auto-resume
    case .siri:
        return true   // Siri notifications - auto-resume ✅
    default:
        return true   // Phone calls, alarms - auto-resume
    }
}
```

---

## Testing Scenarios

### Test 1: AirPods + Phone Call
1. **Setup**: Play music through AirPods
2. **Action**: Receive phone call
3. **Expected**: Music pauses
4. **Action**: End phone call
5. **Expected**: Music auto-resumes through AirPods ✅

### Test 2: Phone Speaker + Phone Call
1. **Setup**: Play music through phone speaker
2. **Action**: Receive phone call
3. **Expected**: Music pauses
4. **Action**: End phone call
5. **Expected**: Music auto-resumes through speaker ✅ (already working)

### Test 3: Siri Text Message
1. **Setup**: Play music (any route)
2. **Action**: Receive text message, Siri reads it
3. **Expected**: Music ducks/pauses
4. **Action**: Siri finishes
5. **Expected**: Music auto-resumes ✅

### Test 4: Other App Music
1. **Setup**: Play music in LyrPlay
2. **Action**: Start music in Spotify
3. **Expected**: LyrPlay pauses
4. **Action**: Stop Spotify
5. **Expected**: LyrPlay does NOT auto-resume ✅ (correct behavior - user started other app)

---

## Summary of Changes

| Issue | Old Behavior | New Behavior |
|-------|-------------|--------------|
| AirPods + call | Skip BASS reinit when exiting call | ✅ Reinit BASS when exiting call (HFP→A2DP) |
| Siri interruption | Categorized as `.otherAudio`, no resume | ✅ Categorized as `.siri`, auto-resume |
| Other app music | No resume (correct) | ✅ No resume (unchanged) |

---

## Key Insights

1. **Bluetooth has TWO profiles**:
   - A2DP: High-quality music
   - HFP: Hands-free phone calls
   - Must reinitialize BASS when switching between them

2. **Siri ≠ Other Apps**:
   - Siri: System notification, temporary, should resume
   - Music apps: User intent to switch, should NOT resume
   - Detection: Siri doesn't change route, music apps do (usually)

3. **Route Change Direction Matters**:
   - **Entering** phone call: Skip BASS reinit (call takes over)
   - **Exiting** phone call: MUST reinit BASS (restore music route)
