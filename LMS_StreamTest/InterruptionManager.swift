// File: InterruptionManager.swift
// Temporary placeholder while the new session orchestration is specified.
import Foundation
import AVFoundation
import os.log

protocol InterruptionManagerDelegate: AnyObject {
    func interruptionDidBegin(type: InterruptionManager.InterruptionType, shouldPause: Bool)
    func interruptionDidEnd(type: InterruptionManager.InterruptionType, shouldResume: Bool)
    func routeDidChange(type: InterruptionManager.RouteChangeType, shouldPause: Bool)
    func audioSessionWasReset()
}

/// Minimal shell that keeps the app compiling while we replace the legacy
/// interruption stack with a single session controller.
final class InterruptionManager: ObservableObject {

    private let logger = OSLog(subsystem: "com.lmsstream", category: "InterruptionManager")

    enum InterruptionType {
        case phoneCall
        case facetimeCall
        case siri
        case alarm
        case otherAudio
        case unknown

        var shouldAutoResume: Bool {
            switch self {
            case .phoneCall, .facetimeCall, .alarm, .siri:
                return true
            case .otherAudio, .unknown:
                return false
            }
        }

        var description: String {
            switch self {
            case .phoneCall: return "Phone Call"
            case .facetimeCall: return "FaceTime Call"
            case .siri: return "Siri"
            case .alarm: return "Alarm"
            case .otherAudio: return "Other Audio App"
            case .unknown: return "Unknown"
            }
        }
    }

    enum RouteChangeType {
        case headphonesDisconnected
        case headphonesConnected
        case carPlayDisconnected
        case carPlayConnected
        case bluetoothDisconnected
        case bluetoothConnected
        case airPlayConnected
        case airPlayDisconnected
        case speakerChange
        case unknown

        var shouldPause: Bool {
            switch self {
            case .headphonesDisconnected, .carPlayDisconnected, .bluetoothDisconnected, .airPlayDisconnected:
                return true
            default:
                return false
            }
        }

        var shouldAutoResume: Bool {
            switch self {
            case .carPlayConnected:
                return true
            default:
                return false
            }
        }

        var description: String {
            switch self {
            case .headphonesDisconnected: return "Headphones Disconnected"
            case .headphonesConnected: return "Headphones Connected"
            case .carPlayDisconnected: return "CarPlay Disconnected"
            case .carPlayConnected: return "CarPlay Connected"
            case .bluetoothDisconnected: return "Bluetooth Disconnected"
            case .bluetoothConnected: return "Bluetooth Connected"
            case .airPlayConnected: return "AirPlay Connected"
            case .airPlayDisconnected: return "AirPlay Disconnected"
            case .speakerChange: return "Speaker Change"
            case .unknown: return "Unknown Route Change"
            }
        }
    }

    weak var delegate: InterruptionManagerDelegate?

    @Published var currentInterruption: InterruptionType?
    @Published var isInterrupted: Bool = false
    @Published var lastRouteChange: RouteChangeType?

    private var wasPlayingBeforeInterruption: Bool = false

    init() {
        os_log(.info, log: logger, "InterruptionManager placeholder initialized")
    }

    func setWasPlayingBeforeInterruption(_ wasPlaying: Bool) {
        wasPlayingBeforeInterruption = wasPlaying
    }

    func getWasPlayingBeforeInterruption() -> Bool {
        wasPlayingBeforeInterruption
    }

    func getCurrentAudioRoute() -> String {
        "Unknown"
    }

    func getInterruptionStatus() -> String {
        isInterrupted ? "Interrupted" : "Normal"
    }
}
