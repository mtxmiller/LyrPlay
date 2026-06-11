#if os(iOS)
import UIKit
import MediaPlayer
import AVFoundation
import WebKit
import os.log

/// UIKit shell for hardware-volume forwarding (GH#75). Owns the hardware
/// plumbing only; every decision lives in `VolumeRockerLogic` (see its
/// header for the state diagram).
///
/// Responsibilities:
/// - KVO on `AVAudioSession.outputVolume` (read-only — BASS owns the
///   session lifecycle, Critical Rule #2; the spike on 2026-06-10 verified
///   KVO fires in all local-player states without manual activation)
/// - hidden MPVolumeView installed on engage / removed on disengage,
///   re-centered to 0.5 so both rocker directions stay detectable
/// - pre-engage volume saved to memory + UserDefaults, restored on
///   disengage (or on next launch if the app was killed mid-engage)
/// - presses forwarded to Material's own `incrementVolume()` /
///   `decrementVolume()` globals via the WebView
/// - 1s playback poll, running ONLY while an external player is selected,
///   to catch local-playback transitions (no shared audio files touched)
final class VolumeRockerForwarder: NSObject, ObservableObject {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "VolumeRocker")
    private static let savedVolumeKey = "VolumeRockerSavedSystemVolume"

    private var logic = VolumeRockerLogic()
    private var volumeView: MPVolumeView?
    /// Press detector: polls the MPVolumeView slider value. `outputVolume` KVO
    /// is NOT used — it freezes after app suspension (see startVolumePolling).
    private var volumePollTimer: Timer?
    private var lastSliderValue: Float?
    private var savedVolume: Float?
    private var pollTimer: Timer?
    private var selectedPlayerID: String?

    weak var webView: WKWebView?

    override init() {
        super.init()
        restoreStaleSaveIfNeeded()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit {
        pollTimer?.invalidate()
        volumePollTimer?.invalidate()
    }

    // MARK: - Inputs

    /// Bridge input: Material reported a player switch (nil = unknown,
    /// e.g. WebView reloading or content process killed).
    func materialPlayerChanged(_ player: MaterialPlayerMessage?) {
        selectedPlayerID = player?.id
        os_log(.info, log: logger, "🔊 Material player: %{public}s",
               player.map { "\($0.name ?? "?") [\($0.id)]" } ?? "unknown")
        reevaluate()
        managePollTimer()
    }

    @objc private func appDidBecomeActive() {
        reevaluate()
        managePollTimer()
    }

    /// Inside `willResignActive`, `UIApplication.applicationState` is still
    /// `.active` (iOS flips it to `.inactive` only after this returns). Reading
    /// it here would keep the rocker engaged across backgrounding — leaving the
    /// `outputVolume` KVO registered while the app is suspended, where it goes
    /// stale and never fires again, so the buttons stop working until a restart.
    /// Force the inactive evaluation so we disengage (tear down KVO + view,
    /// restore phone volume) now and re-engage cleanly on `didBecomeActive`.
    @objc private func appWillResignActive() {
        reevaluate(appActiveOverride: false)
        managePollTimer(appActiveOverride: false)
    }

    // MARK: - Evaluation

    private func reevaluate(appActiveOverride: Bool? = nil) {
        let conditions = VolumeRockerLogic.Conditions(
            selectedPlayerID: selectedPlayerID,
            localPlayerID: SettingsManager.shared.playerMACAddress,
            appActive: appActiveOverride ?? (UIApplication.shared.applicationState == .active),
            localPlayerBusy: Self.isLocalPlayerBusy()
        )
        perform(logic.evaluate(conditions))
    }

    private static func isLocalPlayerBusy() -> Bool {
        // Same truth source the lock screen uses (AudioManager:596).
        let state = AudioManager.shared.audioPlayer.getPlayerState()
        return state == "Playing" || state == "Buffering"
    }

    /// Playback state has no observable — poll at 1s, but ONLY while an
    /// external player is selected and the app is active (the only window
    /// where a playback transition changes engage state).
    private func managePollTimer(appActiveOverride: Bool? = nil) {
        let appActive = appActiveOverride ?? (UIApplication.shared.applicationState == .active)
        let localMAC = SettingsManager.shared.playerMACAddress
        let externalSelected = selectedPlayerID.map {
            $0.caseInsensitiveCompare(localMAC) != .orderedSame
        } ?? false
        let shouldPoll = externalSelected && appActive

        if shouldPoll && pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.reevaluate()
            }
        } else if !shouldPoll {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Actions

    private func perform(_ actions: [VolumeRockerLogic.Action]) {
        for action in actions {
            switch action {
            case .engage: engage()
            case .disengage: disengage()
            case .pressUp: forwardPress(up: true)
            case .pressDown: forwardPress(up: false)
            case .recenter: setSystemVolume(VolumeRockerLogic.recenterTarget)
            }
        }
    }

    private func engage() {
        let current = AVAudioSession.sharedInstance().outputVolume
        savedVolume = current
        UserDefaults.standard.set(current, forKey: Self.savedVolumeKey)
        installVolumeView()
        startVolumePolling()
        os_log(.info, log: logger, "🔊 Engaged — rocker → external player (saved phone volume %.2f)", current)
    }

    private func disengage() {
        // Stop polling BEFORE the restore write so its slider change never
        // feeds the logic (belt and suspenders — logic is disengaged too).
        stopVolumePolling()
        pollTimer?.invalidate()
        pollTimer = nil

        if let restore = savedVolume {
            setSystemVolume(restore)
            os_log(.info, log: logger, "🔊 Disengaged — phone volume restored to %.2f", restore)
        }
        savedVolume = nil
        UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)

        // Remove the view after the restore write has landed; HUD
        // suppression must not outlive engagement.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.savedVolume == nil else { return }
            self.removeVolumeView()
        }
    }

    /// Detect hardware-volume presses by polling the hidden MPVolumeView
    /// slider. We do NOT use `AVAudioSession.outputVolume` KVO: after the app
    /// is suspended — which happens within ~1-2 min whenever the local player
    /// is idle, i.e. exactly the rocker's engaged state — `outputVolume`
    /// freezes and its KVO stops firing, while the MPVolumeView slider keeps
    /// tracking the buttons (device-verified 2026-06-11: outVol stuck at 0.500
    /// while sliderVal climbed 0.500 → 0.562 → 0.625). The slider value works
    /// in every state and needs no audio-session management (Critical Rule #2).
    /// Runs on the main run loop, only while engaged; deltas feed the same
    /// `VolumeRockerLogic` the KVO path used.
    private func startVolumePolling() {
        guard volumePollTimer == nil else { return }
        lastSliderValue = currentSliderValue()
        volumePollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let new = self.currentSliderValue() else { return }
            let old = self.lastSliderValue ?? new
            self.lastSliderValue = new
            guard new != old else { return }
            self.perform(self.logic.volumeChanged(from: old, to: new,
                                                  at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func stopVolumePolling() {
        volumePollTimer?.invalidate()
        volumePollTimer = nil
        lastSliderValue = nil
    }

    /// Current value of the hidden MPVolumeView's embedded slider, or nil if
    /// the view/slider isn't wired up yet.
    private func currentSliderValue() -> Float? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first?.value
    }

    private func forwardPress(up: Bool) {
        let fn = up ? "incrementVolume" : "decrementVolume"
        let inc = up ? "true" : "false"
        // incrementVolume()/decrementVolume() globals are newer than Material
        // 6.4.2 — fall back to the adjustVolume bus event they wrap
        // (server.js handler sends mixer volume ±step to the current player;
        // present in 6.4.2). Returns false only when neither exists so the
        // failure is loggable, not silent.
        let js = """
        (function(){ \
        if (typeof \(fn) === 'function') { \(fn)(); return true; } \
        if (typeof bus !== 'undefined' && bus.$emit) { bus.$emit('adjustVolume', \(inc)); return true; } \
        return false; })()
        """
        guard let webView = webView else {
            os_log(.error, log: logger, "🔊 Press dropped — no WebView reference")
            return
        }
        webView.evaluateJavaScript(js) { [logger] result, error in
            if let error = error {
                // The known dead zone: WebView content process killed.
                os_log(.error, log: logger, "🔊 Press JS failed: %{public}s", error.localizedDescription)
            } else if let handled = result as? Bool, !handled {
                os_log(.error, log: logger, "🔊 Press JS: Material volume globals missing (skin too old?)")
            }
        }
    }

    // MARK: - MPVolumeView plumbing

    private func installVolumeView() {
        guard volumeView == nil else { return }
        let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        keyWindow()?.addSubview(view)
        volumeView = view
    }

    private func removeVolumeView() {
        volumeView?.removeFromSuperview()
        volumeView = nil
    }

    private func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    /// The slider inside MPVolumeView isn't wired immediately after the
    /// view joins the window — write after a short main-queue delay.
    private func setSystemVolume(_ value: Float) {
        installVolumeView()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            guard let slider = self.volumeView?.subviews.compactMap({ $0 as? UISlider }).first else {
                os_log(.error, log: self.logger, "🔊 MPVolumeView slider not found — volume write dropped")
                return
            }
            slider.value = value
        }
    }

    // MARK: - Launch recovery (eng-review 4A)

    /// App killed mid-engage leaves the phone parked at 0.5 with the real
    /// volume persisted. Restore it once on next launch, then clear.
    private func restoreStaleSaveIfNeeded() {
        let persisted = UserDefaults.standard.object(forKey: Self.savedVolumeKey) as? Float
        guard let restore = VolumeRockerLogic.staleRestoreVolume(persisted: persisted) else { return }
        os_log(.info, log: logger, "🔊 Stale mid-engage save found — restoring phone volume to %.2f", restore)
        UserDefaults.standard.removeObject(forKey: Self.savedVolumeKey)
        // Window may not be key yet at init — restore after launch settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.setSystemVolume(restore)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self, self.savedVolume == nil else { return }
                self.removeVolumeView()
            }
        }
    }
}
#endif
