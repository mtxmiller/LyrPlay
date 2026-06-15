import Foundation

/// Pure decision core for hardware-volume forwarding to external players
/// (GH#75). No UIKit — fully unit-testable. The UIKit shell
/// (`VolumeRockerForwarder`) feeds events in and performs the actions out.
///
///     VolumeRockerLogic state machine
///                          external selected && local idle && app active
///        ┌──────────┐  ────────────────────────────────────────►  ┌─────────┐
///        │DISENGAGED│                                             │ ENGAGED │
///        │ (stock   │  ◄────────────────────────────────────────  │ (rocker │
///        │  rocker) │   player → local/unknown                    │ →Material)
///        └──────────┘   | local playback starts | app inactive   └─────────┘
///                                                                    │  ▲
///                                  volumeChanged: ≈0.5 & counter>0   │  │ recenter
///                                  → swallow (self-inflicted write)  ▼  │ (counter→1)
///                                  else delta>0 → pressUp / delta<0 → pressDown
///                                  (coalesced: ≤1 press per 200 ms window)
///
/// Re-center bookkeeping: every `.recenter` the shell performs fires one
/// KVO event landing ≈0.5. `pendingRecenters` swallows exactly that many
/// ≈0.5 events; a REAL press that lands exactly on 0.5 (hardware steps are
/// 0.05 on current devices, so 0.55 → 0.50 is real) classifies normally
/// once the counter is drained. The counter never exceeds 1 because a
/// second slider-write to the same value fires no KVO event.
struct VolumeRockerLogic {

    enum Action: Equatable {
        /// Shell: save current system volume (memory + UserDefaults),
        /// install the hidden MPVolumeView, start KVO.
        case engage
        /// Shell: stop KVO, restore the saved volume, remove the
        /// MPVolumeView, clear the UserDefaults save.
        case disengage
        case pressUp
        case pressDown
        /// Shell: write `recenterTarget` to the hidden slider.
        case recenter
    }

    struct Conditions: Equatable {
        /// Material's selected player MAC, nil while unknown (bridge silent,
        /// WebView reloading/dead).
        var selectedPlayerID: String?
        /// This device's player MAC (SettingsManager.playerMACAddress).
        var localPlayerID: String
        /// True while the app is in the foreground OR transiently inactive
        /// (Control Center / notification pulldown). ONLY true backgrounding
        /// flips this false — a transient inactive must NOT disengage, or the
        /// disengage/re-engage bounce injects phantom presses (GH#75 creep).
        var appActive: Bool
        /// Local player in active playback ("Playing"/"Buffering" — includes
        /// silent-recovery-muted streams, which are live BASS channels).
        var localPlayerBusy: Bool
        /// Master kill-switch (Settings → "Hardware Volume Buttons"). When
        /// false the rocker never engages, whatever the player/app state.
        var featureEnabled: Bool
        /// Selected external player has LMS fixed output
        /// (digitalVolumeControl=0): forwarding volume is a no-op there, so we
        /// stay disengaged and leave the native HUD alone (e.g. a WiiM locked
        /// to fixed volume).
        var selectedPlayerFixedVolume: Bool
    }

    /// Default recenter target. The shell now passes a per-engage baseline
    /// (the user's OWN volume, clamped into the band below) so engaging never
    /// yanks the device volume to 50%; this constant is only the fallback/test
    /// default for `volumeChanged`.
    static let recenterTarget: Float = 0.5
    static let recenterEpsilon: Float = 0.01
    static let coalescingWindow: TimeInterval = 0.2

    /// Working-baseline band. The sensor (system volume) must sit at least one
    /// iOS volume step (1/16 = 0.0625) away from both rails so a press is
    /// detectable in either direction. Clamp the user's real volume into
    /// [1/16, 15/16]; only volumes within one step of mute/max get nudged, and
    /// the original is restored on disengage.
    static let baselineMin: Float = 0.0625
    static let baselineMax: Float = 0.9375

    /// The system-volume value to hold while engaged, derived from the user's
    /// real volume — their own level untouched in the normal midrange, nudged
    /// at most one step only when pinned near mute or max.
    static func workingBaseline(for volume: Float) -> Float {
        min(baselineMax, max(baselineMin, volume))
    }

    private(set) var isEngaged = false
    private(set) var pendingRecenters = 0
    private var lastPressAt: TimeInterval = -.infinity

    /// Re-evaluate engage/disengage whenever any condition may have changed
    /// (bridge message, app state change, playback poll tick).
    mutating func evaluate(_ c: Conditions) -> [Action] {
        let externalSelected: Bool
        if let selected = c.selectedPlayerID {
            externalSelected = selected.caseInsensitiveCompare(c.localPlayerID) != .orderedSame
        } else {
            externalSelected = false
        }
        let shouldEngage = c.featureEnabled && c.appActive && !c.localPlayerBusy
            && externalSelected && !c.selectedPlayerFixedVolume

        if shouldEngage && !isEngaged {
            isEngaged = true
            pendingRecenters = 1
            lastPressAt = -.infinity
            return [.engage, .recenter]
        }
        if !shouldEngage && isEngaged {
            isEngaged = false
            pendingRecenters = 0
            return [.disengage]
        }
        return []
    }

    /// Classify one KVO outputVolume event. `now` is any monotonic clock
    /// (injected for testability).
    mutating func volumeChanged(from old: Float, to new: Float, at now: TimeInterval,
                                target: Float = recenterTarget) -> [Action] {
        guard isEngaged else { return [] }

        // Self-inflicted re-center write lands ≈ the baseline target: swallow
        // exactly one per outstanding recenter.
        if pendingRecenters > 0 && abs(new - target) < Self.recenterEpsilon {
            pendingRecenters -= 1
            return []
        }

        guard new != old else { return [] }

        var actions: [Action] = []
        if now - lastPressAt >= Self.coalescingWindow {
            actions.append(new > old ? .pressUp : .pressDown)
            lastPressAt = now
        }
        // One outstanding recenter is enough — writing the target twice fires
        // no second event, which would strand the counter.
        if pendingRecenters == 0 {
            actions.append(.recenter)
            pendingRecenters += 1
        }
        return actions
    }

    /// Launch recovery rule (eng-review 4A): a persisted pre-engage volume
    /// that was never restored (app killed mid-engage) is restored once,
    /// then cleared. Returns the volume to restore, or nil for no-op.
    static func staleRestoreVolume(persisted: Float?) -> Float? {
        guard let value = persisted, value >= 0.0, value <= 1.0 else { return nil }
        return value
    }
}
