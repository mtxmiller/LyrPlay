// File: InterruptionManager.swift
// Minimal stub - PlaybackSessionController handles all interruption logic
import Foundation
import os.log

/// Minimal stub that provides route change description for logging
/// All actual interruption handling is done by PlaybackSessionController
final class InterruptionManager: ObservableObject {

    private let logger = OSLog(subsystem: "com.lmsstream", category: "InterruptionManager")

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

    @Published var lastRouteChange: RouteChangeType?

    init() {
        os_log(.info, log: logger, "InterruptionManager stub initialized")
    }

    func getCurrentAudioRoute() -> String {
        "Unknown"
    }

    func getInterruptionStatus() -> String {
        "Normal"
    }
}
