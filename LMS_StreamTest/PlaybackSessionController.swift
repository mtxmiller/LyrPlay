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

    func ensureActive(context: ActivationContext) {
        workQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                if self.audioSession.category != .playback || self.audioSession.mode != .default {
                    try self.audioSession.configureCategory(.playback, mode: .default, options: [])
                    os_log(.info, log: self.logger, "🎛️ Session category set for playback")
                }

                try self.audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
                os_log(.info, log: self.logger, "🔊 Session activated (%{public}s)", context.rawValue)
            } catch {
                os_log(.error, log: self.logger, "❌ Session activation failed (%{public}s): %{public}s",
                       context.rawValue, error.localizedDescription)
            }
        }
    }

    func deactivateIfNeeded() {
        workQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                try self.audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
                os_log(.info, log: self.logger, "🔇 Session deactivated")
            } catch {
                os_log(.error, log: self.logger, "❌ Failed to deactivate session: %{public}s", error.localizedDescription)
            }
        }
    }

    func refreshRemoteCommandCenter() {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.configureRemoteCommands()
        }
    }

    // MARK: - Remote Commands
    private func configureRemoteCommands() {
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
        ensureActive(context: command.activationContext)

        guard let coordinator = slimProtoProvider?() else {
            os_log(.error, log: logger, "❌ SlimProto coordinator unavailable for remote command")
            return .commandFailed
        }

        DispatchQueue.main.async {
            coordinator.sendLockScreenCommand(command.slimCommand)
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
                DispatchQueue.main.async { [weak self] in
                    self?.playbackController?.pause()
                }
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let context = interruptionContext
            let shouldResume = options.contains(.shouldResume) && (context?.shouldAutoResume ?? false)

            os_log(.info, log: logger, "✅ Interruption ended (%{public}s, shouldResume=%{public}s)",
                   context?.type.rawValue ?? InterruptionType.unknown.rawValue,
                   shouldResume ? "YES" : "NO")

            interruptionContext = nil

            guard shouldResume else { return }

            ensureActive(context: .serverResume)
            DispatchQueue.main.async { [weak self] in
                self?.playbackController?.play()
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

        if currentHasCarPlay && !isCarPlayActive {
            isCarPlayActive = true
            handleCarPlayConnected()
        } else if !currentHasCarPlay && (isCarPlayActive || previousHadCarPlay) {
            isCarPlayActive = false
            handleCarPlayDisconnected()
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        os_log(.error, log: logger, "🔄 Media services reset detected")
        ensureActive(context: .backgroundRefresh)
    }

    // MARK: - CarPlay Handling
    private func handleCarPlayConnected() {
        guard !shouldThrottleCarPlayEvent() else { return }
        os_log(.info, log: logger, "🚗 CarPlay connected - ensuring session active and syncing with LMS")
        ensureActive(context: .userInitiatedPlay)

        let shouldResume = wasPlayingBeforeCarPlayDetach
        wasPlayingBeforeCarPlayDetach = false

        workQueue.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let coordinator = self.slimProtoProvider?() else { return }

                if !coordinator.isConnected {
                    coordinator.connect()
                }

                if shouldResume {
                    coordinator.sendLockScreenCommand("play")
                }
            }
        }
    }

    private func handleCarPlayDisconnected() {
        guard !shouldThrottleCarPlayEvent() else { return }
        os_log(.info, log: logger, "🚗 CarPlay disconnected - pausing playback and saving state")
        wasPlayingBeforeCarPlayDetach = playbackController?.isPlaying ?? false
        beginBackgroundTask(named: "CarPlayDisconnect")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.wasPlayingBeforeCarPlayDetach {
                self.playbackController?.pause()
            }

            if let coordinator = self.slimProtoProvider?() {
                coordinator.saveCurrentPositionForRecovery()
                coordinator.sendLockScreenCommand("pause")
            }
            self.endBackgroundTask()
        }
    }

    // MARK: - Interruption Helpers
    private func determineInterruptionType(userInfo: [AnyHashable: Any]) -> InterruptionType {
        if let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
           let reason = AVAudioSession.InterruptionReason(rawValue: reasonValue) {
            switch reason {
            case .appWasSuspended, .builtInMicMuted:
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

        if audioSession.otherAudioIsPlaying {
            return .otherAudio
        }

        let outputs = audioSession.currentOutputs
        if outputs.contains(.builtInReceiver) || outputs.contains(.bluetoothHFP) {
            return .phoneCall
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
            return false
        default:
            return true
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
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
