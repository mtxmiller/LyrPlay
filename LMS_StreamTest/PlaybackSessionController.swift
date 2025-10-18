// File: PlaybackSessionController.swift
// Central coordinator for playback session state, AVAudioSession activation,
// lock-screen commands, and route/interruption events.
import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import os.log

// MARK: - Protocol Abstractions
protocol AudioSessionManaging {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var currentOutputs: [AVAudioSession.Port] { get }
    var otherAudioIsPlaying: Bool { get }
    func configureCategory(_ category: AVAudioSession.Category,
                           mode: AVAudioSession.Mode,
                           options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionManaging {
    func configureCategory(_ category: AVAudioSession.Category,
                           mode: AVAudioSession.Mode,
                           options: AVAudioSession.CategoryOptions) throws {
        try setCategory(category, mode: mode, options: options)
    }

    var currentOutputs: [AVAudioSession.Port] {
        currentRoute.outputs.map { $0.portType }
    }

    var otherAudioIsPlaying: Bool { self.isOtherAudioPlaying }
}

protocol SlimProtoControlling: AnyObject {
    var isConnected: Bool { get }
    func connect()
    func sendLockScreenCommand(_ command: String)
    func saveCurrentPositionForRecovery()
}

extension SlimProtoCoordinator: SlimProtoControlling {}

protocol AudioPlaybackControlling: AnyObject {
    func play()
    func pause()
    var isPlaying: Bool { get }
    func handleAudioRouteChange()  // NEW: Route change handling
}

extension AudioManager: AudioPlaybackControlling {
    var isPlaying: Bool { getPlayerState() == "Playing" }
}

// MARK: - PlaybackSessionController
final class PlaybackSessionController {
    enum ActivationContext: String {
        case userInitiatedPlay
        case serverResume
        case backgroundRefresh
    }

    private enum RemoteCommand {
        case play, pause, next, previous

        var slimCommand: String {
            switch self {
            case .play: return "play"
            case .pause: return "pause"
            case .next: return "next"
            case .previous: return "previous"
            }
        }

        var activationContext: ActivationContext {
            switch self {
            case .play: return .userInitiatedPlay
            case .pause: return .backgroundRefresh
            case .next, .previous: return .userInitiatedPlay
            }
        }
    }

    private enum InterruptionType: String {
        case phoneCall
        case facetimeCall
        case siri
        case alarm
        case otherAudio
        case unknown
    }

    private struct InterruptionContext {
        let type: InterruptionType
        let beganAt: Date
        let shouldAutoResume: Bool
        let wasPlaying: Bool
    }

    static let shared = PlaybackSessionController()

    private let logger = OSLog(subsystem: "com.lmsstream", category: "PlaybackSessionController")
    private let audioSession: AudioSessionManaging
    private let center: NotificationCenter
    private let commandCenter: MPRemoteCommandCenter
    private let workQueue = DispatchQueue(label: "com.lmsstream.playback-session", qos: .userInitiated)

    private weak var playbackController: AudioPlaybackControlling?
    private var slimProtoProvider: (() -> SlimProtoControlling?)?

    private var observersRegistered = false
    private var isCarPlayActive = false
    private var interruptionContext: InterruptionContext?
    private var wasPlayingBeforeCarPlayDetach = false
    private var lastCarPlayEvent: Date?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(audioSession: AudioSessionManaging = AVAudioSession.sharedInstance(),
         notificationCenter: NotificationCenter = .default,
         commandCenter: MPRemoteCommandCenter = MPRemoteCommandCenter.shared()) {
        self.audioSession = audioSession
        self.center = notificationCenter
        self.commandCenter = commandCenter
    }

    func configure(audioManager: AudioPlaybackControlling,
                   slimProtoProvider: @escaping () -> SlimProtoControlling?) {
        self.playbackController = audioManager
        self.slimProtoProvider = slimProtoProvider

        os_log(.info, log: logger, "PlaybackSessionController configured")
        refreshRemoteCommandCenter()
        registerForSystemNotificationsIfNeeded()
    }

    // REMOVED: Manual AVAudioSession management - BASS handles automatically
    // ensureActive() and deactivateIfNeeded() no longer needed
    // BASS auto-manages iOS audio session activation/deactivation

    func refreshRemoteCommandCenter() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureRemoteCommands()
        }
    }

    // MARK: - Remote Commands
    private func configureRemoteCommands() {
        // CRITICAL: iOS requires an ACTIVE audio session to show lock screen controls
        // Activate session ONCE during setup, then BASS manages everything after
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            os_log(.info, log: logger, "🔒 Audio session activated for lock screen controls setup")
        } catch {
            os_log(.error, log: logger, "❌ Failed to activate session for lock screen: %{public}s", error.localizedDescription)
        }

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true

        commandCenter.stopCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.handleRemoteCommand(.play) ?? .commandFailed
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.handleRemoteCommand(.pause) ?? .commandFailed
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.handleRemoteCommand(.next) ?? .commandFailed
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.handleRemoteCommand(.previous) ?? .commandFailed
        }

        os_log(.info, log: logger, "✅ Remote command center configured")
    }

    private func handleRemoteCommand(_ command: RemoteCommand) -> MPRemoteCommandHandlerStatus {
        beginBackgroundTask(named: "LockScreenCommand")
        // BASS auto-manages audio session - no manual activation needed

        if command == .play {
            wasPlayingBeforeCarPlayDetach = false
        }

        guard let coordinator = slimProtoProvider?() else {
            os_log(.error, log: logger, "❌ SlimProto coordinator unavailable for remote command")
            return .commandFailed
        }

        DispatchQueue.main.async {
            coordinator.sendLockScreenCommand(command.slimCommand)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            self?.endBackgroundTask()
        }

        os_log(.info, log: logger, "🔒 Remote command handled: %{public}s", command.slimCommand)
        return .success
    }

    // MARK: - System Notifications
    private func registerForSystemNotificationsIfNeeded() {
        guard !observersRegistered else { return }
        observersRegistered = true

        center.addObserver(self,
                           selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification,
                           object: nil)

        center.addObserver(self,
                           selector: #selector(handleRouteChange(_:)),
                           name: AVAudioSession.routeChangeNotification,
                           object: nil)

        center.addObserver(self,
                           selector: #selector(handleMediaServicesReset(_:)),
                           name: AVAudioSession.mediaServicesWereResetNotification,
                           object: nil)
    }

    deinit {
        center.removeObserver(self)
    }

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
                // Send server pause command instead of local CBass pause
                slimProtoProvider?()?.sendLockScreenCommand("pause")
                os_log(.info, log: logger, "📡 Sent server pause command for interruption")
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let context = interruptionContext
            // PHONE CALL FIX: Don't rely on iOS .shouldResume flag - it's unreliable for phone calls
            // Apple docs: "There is no guarantee that a begin interruption will have an end interruption"
            // Trust our own shouldAutoResume logic instead
            let shouldResume = context?.shouldAutoResume ?? false

            os_log(.info, log: logger, "✅ Interruption ended (%{public}s, iOS.shouldResume=%{public}s, app.shouldResume=%{public}s)",
                   context?.type.rawValue ?? InterruptionType.unknown.rawValue,
                   options.contains(.shouldResume) ? "YES" : "NO",
                   shouldResume ? "YES" : "NO")

            interruptionContext = nil

            guard shouldResume else { return }

            // BASS auto-manages audio session and route changes
            // Simply send server play command - BASS handles device routing automatically
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.slimProtoProvider?()?.sendLockScreenCommand("play")
                os_log(.info, log: self?.logger ?? OSLog.default, "📡 Sent server play command for interruption resume")
            }
        @unknown default:
            break
        }
    }

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

        // Determine if this is a CarPlay event (will be handled by specific CarPlay handlers below)
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

        // BASS auto-manages route changes - no manual intervention needed
        // Log route changes for debugging, but BASS handles device switching automatically
        if !isCarPlayEvent && !isEnteringPhoneCall {
            if previousHadPhoneRoute && !currentHasPhoneRoute {
                os_log(.info, log: logger, "📞 Exited phone call route - BASS automatically switches to music profile")
            } else {
                os_log(.info, log: logger, "🔀 Route change detected - BASS auto-switching to new device")
            }
        }

        // PHONE CALL FIX: Check if we need to resume after interruption (phone call, etc.)
        // iOS often doesn't fire interruption ended notification - handle resume via route change
        // If we have an active interruption context AND we're now on a normal (non-phone) route, resume
        if !currentHasPhoneRoute && interruptionContext != nil {
            if let context = interruptionContext, context.shouldAutoResume {
                os_log(.info, log: logger, "📞 Interruption ended via route change - auto-resuming")

                // Clear interruption context - we're handling it now
                interruptionContext = nil

                // Send play command after a delay to allow BASS reinit to complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.slimProtoProvider?()?.sendLockScreenCommand("play")
                    os_log(.info, log: self?.logger ?? OSLog.default, "📞 Sent play command after interruption ended")
                }
            } else {
                os_log(.info, log: logger, "📞 Interruption ended but shouldNotResume")
                interruptionContext = nil
            }
        }

        // Handle CarPlay connect/disconnect (these have their own session management)
        if currentHasCarPlay && !isCarPlayActive {
            isCarPlayActive = true
            handleCarPlayConnected()
        } else if !currentHasCarPlay && (isCarPlayActive || previousHadCarPlay) {
            isCarPlayActive = false
            handleCarPlayDisconnected()
        }

        // Handle AirPods/headphone disconnection (but not CarPlay, which is handled separately)
        if reason == .oldDeviceUnavailable && !previousHadCarPlay {
            let wasPlaying = playbackController?.isPlaying ?? false
            if wasPlaying {
                os_log(.info, log: logger, "🎧 AirPods/headphones disconnected - pausing server")
                slimProtoProvider?()?.sendLockScreenCommand("pause")
            }
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        os_log(.error, log: logger, "🔄 Media services reset detected - BASS will auto-reinitialize")
        // BASS automatically handles media services reset - no manual intervention needed
    }

    // MARK: - CarPlay Handling
    private func handleCarPlayConnected() {
        guard !shouldThrottleCarPlayEvent() else { return }
        refreshRemoteCommandCenter()
        endBackgroundTask()
        os_log(.info, log: logger, "🚗 CarPlay connected - BASS auto-switching to CarPlay audio route")

        // BASS automatically handles CarPlay route switching - no manual session management needed
        wasPlayingBeforeCarPlayDetach = false
    }

    private func handleCarPlayDisconnected() {
        guard !shouldThrottleCarPlayEvent() else { return }
        os_log(.info, log: logger, "🚗 CarPlay disconnected - BASS auto-switching from CarPlay route")
        wasPlayingBeforeCarPlayDetach = playbackController?.isPlaying ?? false
        beginBackgroundTask(named: "CarPlayDisconnect")

        // BASS automatically handles route switching from CarPlay - just send server pause command
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let coordinator = self.slimProtoProvider?() {
                coordinator.sendLockScreenCommand("pause")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                self.endBackgroundTask()
            }
        }
    }

    // MARK: - Interruption Helpers
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
            default:
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

    private func shouldThrottleCarPlayEvent() -> Bool {
        let now = Date()
        if let last = lastCarPlayEvent, now.timeIntervalSince(last) < 0.6 {
            os_log(.info, log: logger, "🚗 Ignoring rapid CarPlay route change (debounced)")
            return true
        }
        lastCarPlayEvent = now
        return false
    }

    private func beginBackgroundTask(named name: String) {
        DispatchQueue.main.async {
            self.endBackgroundTask()
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        DispatchQueue.main.async {
            guard self.backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
    }
}

private func describe(reason: AVAudioSession.RouteChangeReason) -> String {
    switch reason {
    case .newDeviceAvailable: return "New Device Available"
    case .oldDeviceUnavailable: return "Old Device Unavailable"
    case .categoryChange: return "Category Change"
    case .override: return "Override"
    case .wakeFromSleep: return "Wake From Sleep"
    case .noSuitableRouteForCategory: return "No Suitable Route"
    case .routeConfigurationChange: return "Route Configuration Change"
    @unknown default: return "Unknown"
    }
}
