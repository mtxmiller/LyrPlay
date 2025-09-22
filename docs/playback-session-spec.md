# Playback Session Management Specification

## Goals
- Provide a single, deterministic coordinator for audio session state and transport control.
- Support recovery from three primary disruption sources:
  1. Lock screen / remote-command initiated play or pause.
  2. System interruptions (phone calls, Siri, alarms, other audio ownership changes).
  3. CarPlay attach / detach cycles, including reconnecting to LMS when needed.
- Replace the legacy `InterruptionManager` + distributed CarPlay helpers with a modular design that is easy to reason about and test.

## Target Architecture
- Introduce a `PlaybackSessionController` responsible for:
  - Owning the `AVAudioSession` lifecycle, activation retries, and category configuration.
  - Managing a finite set of playback states (`idle`, `preparing`, `playing`, `paused`, `interrupted`).
  - Acting as delegate for system notifications (interruption, route change, media services reset) and forwarding high-level intents to `AudioManager`/`SlimProtoCoordinator`.
  - Coordinating lock screen command handling through `MPRemoteCommandCenter`.
- Provide thin adapters:
  - `SystemEventMonitor`: wraps NotificationCenter observers and forwards events to the controller in a serial queue.
  - `SlimProtoRecoveryAdapter`: encapsulates LMS reconnect, playlist-seek recovery, and position persistence.

## Feature Objectives
### 1. Lock Screen Recovery
- **Scenario:** User taps play from lock screen after app lost focus or server dropped connection.
- **Expected Flow:**
  1. `MPRemoteCommandCenter` play triggers controller `handleRemoteCommand(.play)`.
  2. Controller ensures `AVAudioSession` is active (retry with exponential backoff if activation fails due to competing audio).
  3. Controller asks `SlimProtoRecoveryAdapter` to resume: reconnect if needed, request playlist jump if we have persisted position, otherwise send simple `play`.
  4. On success, controller transitions to `playing` and updates Now Playing info.
- **Edge Cases:**
  - Lock screen command arrives while already `playing` → treat as no-op.
  - LMS reject or timeout → surface error toast/log, revert to `paused` state.
  - Activation fails because another app owns audio → store pending resume and retry once foregrounded.

### 2. Interruption Management
- **Interruptions Covered:** phone calls (CallKit), Siri, alarms, route loss, media services reset.
- **Policy:**
  - Phone/FaceTime: pause playback, remember prior state, auto-resume when `.shouldResume` and user was previously playing.
  - Siri/short voice sessions: treat similar to phone but allow quick resume.
  - Other audio apps: pause but do **not** auto-resume unless user explicitly commands play (per iOS guidelines).
  - Media services reset: tear down and rebuild both audio engine and SlimProto connection.
- **Implementation Notes:**
  - All interruption events flow through controller’s state machine. No direct pause/play calls from observers.
  - Controller records `interruptionContext` containing reason, timestamp, and resume eligibility.
  - Provide unit tests that simulate `AVAudioSessionInterruptionNotification` payloads and verify state transitions + delegate callbacks.

### 3. CarPlay Transitions
- **Attach:**
  1. `CPInterfaceController` or route-change indicates CarPlay route available.
  2. Controller activates audio session, refreshes Now Playing metadata, and triggers SlimProto recovery (similar to lock screen) ensuring commands go out only after route stabilises (~500 ms debounce).
- **Detach:**
  1. On car route removal, controller pauses playback, persists position via `SlimProtoRecoveryAdapter`, and optionally leaves session active if user requests.
  2. Background task ensures we remain eligible for quick resume when user exits vehicle.
- **Reconnection:** If SlimProto was dropped during vehicle transition, controller triggers reconnect workflow before playback resumes.
- **Testing:**
  - Instrument `AVAudioSessionRouteChangeReason` flows in simulator (or by dependency injection) to cover `newDeviceAvailable`, `oldDeviceUnavailable` cases.
  - Manual on-road validation checklist referencing controller debug logs.

## Deliverables & Phases
1. **Phase 0** – Placeholder implementation (done).
2. **Phase 1** – PlaybackSessionController skeleton + lock-screen recovery (done).
3. **Phase 2** – Interruption handling with deterministic tests (done).
4. **Phase 3** – CarPlay attach/detach recovery & LMS reconnect (done).
5. **Phase 4** – Polish interruption heuristics, debounce CarPlay, background assertions, telemetry, documentation (in progress).

### Current Status
- `PlaybackSessionController` owns AVAudioSession activation, MPRemoteCommandCenter, and system notifications with protocol seams for testability.
- Interruption handling records context (type, resume policy, previous playback state) and avoids auto-resume when audio was pre-empted by another app.
- CarPlay transitions debounce rapid route changes, persist position on disconnect, and optionally auto-resume when the user was previously playing.
- Unit tests (`PlaybackSessionControllerTests`) cover activation, interruption resume/no-resume paths, and CarPlay attach/detach flows via fakes.
- Remaining work: enrich interruption classification (Siri/phone), expand logging/metrics, add background task telemetry, and verify behaviour on device.

## Open Questions
- Do we expose controller state to SwiftUI views (for debugging) or keep internal?
- Should CarPlay reconnection reuse existing SlimProto playlist recovery or design a new server API?
- How do we surface errors to the user (banner vs silent log)?
- Do we need background audio assertions beyond `AVAudioSession` activation during CarPlay detach?

Document to be updated as implementation details solidify.
