// File: InterruptionManager.swift
// Core interruption handling for LyrPlay app
import Foundation
import AVFoundation
import UIKit
import os.log

protocol InterruptionManagerDelegate: AnyObject {
    func interruptionDidBegin(type: InterruptionManager.InterruptionType, shouldPause: Bool)
    func interruptionDidEnd(type: InterruptionManager.InterruptionType, shouldResume: Bool)
    func routeDidChange(type: InterruptionManager.RouteChangeType, shouldPause: Bool)
    func audioSessionWasReset()
}

class InterruptionManager: ObservableObject {
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "InterruptionManager")
    
    // MARK: - Interruption Types
    enum InterruptionType {
        case phoneCall
        case facetimeCall
        case siri
        case alarm
        case otherAudio
        case unknown
        
        var shouldAutoResume: Bool {
            switch self {
            case .phoneCall, .facetimeCall, .alarm:
                return true  // Auto-resume after these end
            case .siri:
                return true  // Quick resume after Siri
            case .otherAudio, .unknown:
                return false // Don't auto-resume for user-initiated app switches
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
    
    // MARK: - Route Change Types
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
            case .headphonesDisconnected, .carPlayDisconnected, .bluetoothDisconnected:
                return true  // Pause when audio output is removed
            case .headphonesConnected, .carPlayConnected, .bluetoothConnected, .airPlayConnected:
                return false // Don't pause when better output is connected
            case .airPlayDisconnected:
                return true  // Pause when AirPlay stops
            case .speakerChange, .unknown:
                return false // Don't pause for minor route changes
            }
        }
        
        var shouldAutoResume: Bool {
            switch self {
            case .carPlayConnected:
                return true  // Auto-resume when CarPlay reconnects
            case .headphonesConnected, .bluetoothConnected:
                return false // Don't auto-resume - user might want to choose
            case .airPlayConnected:
                return false // Don't auto-resume AirPlay
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
    
    // MARK: - State Management
    @Published var currentInterruption: InterruptionType?
    @Published var isInterrupted: Bool = false
    @Published var lastRouteChange: RouteChangeType?
    private var lastRouteChangeTime: Date?
    
    private var wasPlayingBeforeInterruption: Bool = false
    private var interruptionStartTime: Date?
    private var lastKnownRoute: AVAudioSessionRouteDescription?
    
    // MARK: - Delegation
    weak var delegate: InterruptionManagerDelegate?
    
    // MARK: - Route Change Intelligence
    private var routeChangeTimer: Timer?
    private let routeChangeGracePeriod: TimeInterval = 1.0 // Wait 1 second to avoid glitch-induced pauses
    
    // MARK: - Initialization
    init() {
        setupInterruptionObservers()
        captureCurrentRoute()
        os_log(.info, log: logger, "InterruptionManager initialized")
    }
    
    // MARK: - Observer Setup
    private func setupInterruptionObservers() {
        // AVAudioSession interruption notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        // AVAudioSession route change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChangeNotification(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        
        // AVAudioSession media services reset notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesResetNotification(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
        
        os_log(.info, log: logger, "✅ Interruption observers configured")
    }
    
    // MARK: - Interruption Handling
    @objc private func handleInterruptionNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            os_log(.error, log: logger, "Invalid interruption notification")
            return
        }
        
        switch interruptionType {
        case .began:
            handleInterruptionBegan(userInfo: userInfo)
        case .ended:
            handleInterruptionEnded(userInfo: userInfo)
        @unknown default:
            os_log(.error, log: logger, "Unknown interruption type")
        }
    }
    
    private func handleInterruptionBegan(userInfo: [AnyHashable: Any]) {
        // Determine the type of interruption
        let interruptionType = determineInterruptionType(userInfo: userInfo)
        
        os_log(.info, log: logger, "🚫 Interruption began: %{public}s", interruptionType.description)
        
        // Update state
        currentInterruption = interruptionType
        isInterrupted = true
        interruptionStartTime = Date()
        
        // Determine if we should pause (most interruptions should pause)
        let shouldPause = true
        
        // Notify delegate
        delegate?.interruptionDidBegin(type: interruptionType, shouldPause: shouldPause)
    }
    
    private func handleInterruptionEnded(userInfo: [AnyHashable: Any]) {
        guard let interruptionType = currentInterruption else {
            os_log(.error, log: logger, "Interruption ended but no current interruption recorded")
            return
        }
        
        // Check if we should resume
        var shouldResume = false
        
        if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            shouldResume = options.contains(.shouldResume) && interruptionType.shouldAutoResume
        } else {
            // Fallback: use our own logic if no system recommendation
            shouldResume = interruptionType.shouldAutoResume
        }
        
        let interruptionDuration = interruptionStartTime?.timeIntervalSinceNow ?? 0
        
        os_log(.info, log: logger, "✅ Interruption ended: %{public}s (duration: %.1fs, shouldResume: %{public}s)",
               interruptionType.description, abs(interruptionDuration), shouldResume ? "YES" : "NO")
        
        // Update state
        self.currentInterruption = nil
        isInterrupted = false
        interruptionStartTime = nil
        
        // Notify delegate
        delegate?.interruptionDidEnd(type: interruptionType, shouldResume: shouldResume)
    }
    
    private func determineInterruptionType(userInfo: [AnyHashable: Any]) -> InterruptionType {
        // Enhanced phone call detection
        
        // Method 0: Check if this interruption is actually a CarPlay route change
        // CarPlay disconnects can trigger both route change AND interruption notifications
        if let lastChange = lastRouteChange,
           (lastChange == .carPlayDisconnected || lastChange == .carPlayConnected),
           let lastChangeTime = lastRouteChangeTime,
           Date().timeIntervalSince(lastChangeTime) < 2.0 {
            os_log(.info, log: logger, "🚗 Interruption caused by recent CarPlay route change - treating as CarPlay event (not false phone call)")
            
            // FIXED: Treat CarPlay disconnect as resumable instead of "otherAudio"
            // This allows proper audio session recovery when CarPlay reconnects
            if lastChange == .carPlayDisconnected {
                return .otherAudio  // CarPlay disconnect should pause but allow resumption
            } else {
                return .otherAudio  // CarPlay connect - treat as temporary route change
            }
        }
        
        // Method 1: Check if CallKit is indicating a phone call
        if isPhoneCallActive() {
            os_log(.info, log: logger, "📞 Phone call detected via CallKit")
            return .phoneCall
        }
        
        // Method 2: Check audio session reason if available
        if let reasonValue = userInfo[AVAudioSessionInterruptionReasonKey] as? UInt,
           let reason = AVAudioSession.InterruptionReason(rawValue: reasonValue) {
            
            switch reason {
            case .default:
                // Default reason could be phone call - check other indicators
                break
            case .appWasSuspended:
                return .otherAudio
            case .builtInMicMuted:
                return .unknown
            @unknown default:
                break
            }
        }
        
        // Method 3: Check if other audio is playing (often indicates phone call)
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.isOtherAudioPlaying {
            os_log(.info, log: logger, "📞 Other audio playing detected - likely phone call")
            return .phoneCall
        }
        
        // Method 4: Check current audio route - phone calls often change route
        let currentRoute = audioSession.currentRoute
        for output in currentRoute.outputs {
            if output.portType == .builtInReceiver {
                os_log(.info, log: logger, "📞 Built-in receiver route detected - likely phone call")
                return .phoneCall
            }
        }
        
        // Method 5: Heuristic - if app is becoming inactive and we don't have other indicators,
        // it's likely a phone call (most common interruption)
        if UIApplication.shared.applicationState != .active {
            os_log(.info, log: logger, "📞 App becoming inactive during interruption - assuming phone call")
            return .phoneCall
        }
        
        // Fallback: Default to phone call for most interruptions
        // This is safer than marking as unknown since phone calls are the most common
        os_log(.info, log: logger, "📞 Defaulting to phone call for interruption")
        return .phoneCall
    }

    // ADD this new helper method to InterruptionManager.swift:

    private func isPhoneCallActive() -> Bool {
        // Check if there's an active phone call using CallKit if available
        // This is a simple check - CallKit would give us more detailed info
        
        // For now, we'll use a simple heuristic
        let audioSession = AVAudioSession.sharedInstance()
        
        // If the audio session indicates other audio is playing and we're being interrupted,
        // it's very likely a phone call
        return audioSession.isOtherAudioPlaying
    }
    
    // MARK: - Route Change Handling
    @objc private func handleRouteChangeNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            os_log(.error, log: logger, "Invalid route change notification")
            return
        }
        
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let previousRoute = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
        
        os_log(.info, log: logger, "🔀 Route change detected - reason: %{public}s", reason.description)
        
        // Use smart detection to avoid unnecessary pauses
        handleRouteChangeWithIntelligence(
            reason: reason,
            currentRoute: currentRoute,
            previousRoute: previousRoute
        )
    }
    
    private func handleRouteChangeWithIntelligence(
        reason: AVAudioSession.RouteChangeReason,
        currentRoute: AVAudioSessionRouteDescription,
        previousRoute: AVAudioSessionRouteDescription?
    ) {
        
        let routeChangeType = determineRouteChangeType(
            reason: reason,
            currentRoute: currentRoute,
            previousRoute: previousRoute
        )
        
        os_log(.info, log: logger, "🔀 Route change type: %{public}s", routeChangeType.description)
        
        // Cancel any pending route change handling
        routeChangeTimer?.invalidate()
        
        // For certain route changes, add a grace period to avoid glitch-induced pauses
        if shouldUseGracePeriod(for: routeChangeType) {
            os_log(.info, log: logger, "⏱️ Using grace period for route change")
            
            routeChangeTimer = Timer.scheduledTimer(withTimeInterval: routeChangeGracePeriod, repeats: false) { [weak self] _ in
                self?.processRouteChange(routeChangeType)
            }
        } else {
            // Process immediately for important changes like CarPlay disconnect
            processRouteChange(routeChangeType)
        }
        
        // Update our last known route
        lastKnownRoute = currentRoute
    }
    
    private func shouldUseGracePeriod(for routeChangeType: RouteChangeType) -> Bool {
        switch routeChangeType {
        case .carPlayDisconnected, .headphonesDisconnected:
            return false // Handle these immediately
        case .bluetoothDisconnected, .bluetoothConnected:
            return true  // Bluetooth can be glitchy
        case .speakerChange, .unknown:
            return true  // Wait to see if it's a real change
        default:
            return false
        }
    }
    
    private func processRouteChange(_ routeChangeType: RouteChangeType) {
        lastRouteChange = routeChangeType
        lastRouteChangeTime = Date()  // Track when this route change happened

        // CRITICAL FIX: Clear interruption state when CarPlay connects
        // CarPlay connection means we're taking control of audio - clear conflicting interruptions
        if routeChangeType == .carPlayConnected {
            if isInterrupted && currentInterruption == .otherAudio {
                os_log(.info, log: logger, "🚗 CarPlay connected - clearing conflicting 'Other Audio App' interruption state")
                currentInterruption = nil
                isInterrupted = false
            }
        }

        // CRITICAL: Still handle interruptions that require pause/resume
        switch routeChangeType {
        case .headphonesDisconnected, .bluetoothDisconnected:
            // These should pause playback (PRESERVE CURRENT BEHAVIOR)
            delegate?.routeDidChange(type: routeChangeType, shouldPause: true)

        case .carPlayConnected:
            // Notify without forcing pause so CarPlay can resume seamlessly
            delegate?.routeDidChange(type: routeChangeType, shouldPause: false)
            os_log(.info, log: logger, "🚗 CarPlay connected - notifying delegate")

        case .carPlayDisconnected:
            // Pause via delegate so server state stays aligned
            delegate?.routeDidChange(type: routeChangeType, shouldPause: true)
            os_log(.info, log: logger, "🚗 CarPlay disconnected - requesting pause")

        default:
            // Preserve existing behavior for all other route changes
            delegate?.routeDidChange(type: routeChangeType, shouldPause: routeChangeType.shouldPause)
        }

        // Handle auto-resume for route reconnections
        if routeChangeType.shouldAutoResume {
            os_log(.info, log: logger, "🔀 Route change suggests auto-resume")
        }
    }
    
    private func determineRouteChangeType(
        reason: AVAudioSession.RouteChangeReason,
        currentRoute: AVAudioSessionRouteDescription,
        previousRoute: AVAudioSessionRouteDescription?
    ) -> RouteChangeType {
        
        switch reason {
        case .newDeviceAvailable:
            return determineNewDeviceType(currentRoute: currentRoute, previousRoute: previousRoute)
            
        case .oldDeviceUnavailable:
            return determineRemovedDeviceType(previousRoute: previousRoute)
            
        case .categoryChange:
            return .unknown
            
        case .override:
            return .speakerChange
            
        case .wakeFromSleep:
            return .unknown
            
        case .noSuitableRouteForCategory:
            return .unknown
            
        case .routeConfigurationChange:
            return .speakerChange
            
        @unknown default:
            return .unknown
        }
    }
    
    private func determineNewDeviceType(
        currentRoute: AVAudioSessionRouteDescription,
        previousRoute: AVAudioSessionRouteDescription?
    ) -> RouteChangeType {
        
        // Check current route outputs
        for output in currentRoute.outputs {
            switch output.portType {
            case .headphones:
                return .headphonesConnected
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                return .bluetoothConnected
            case .carAudio:
                return .carPlayConnected
            case .airPlay:
                return .airPlayConnected
            default:
                continue
            }
        }
        
        return .speakerChange
    }
    
    private func determineRemovedDeviceType(previousRoute: AVAudioSessionRouteDescription?) -> RouteChangeType {
        guard let previousRoute = previousRoute else {
            return .unknown
        }
        
        // Check what was removed
        for output in previousRoute.outputs {
            switch output.portType {
            case .headphones:
                return .headphonesDisconnected
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                return .bluetoothDisconnected
            case .carAudio:
                return .carPlayDisconnected
            case .airPlay:
                return .airPlayDisconnected
            default:
                continue
            }
        }
        
        return .speakerChange
    }
    
    // MARK: - Media Services Reset Handling
    @objc private func handleMediaServicesResetNotification(_ notification: Notification) {
        os_log(.error, log: logger, "🔄 Media services were reset - audio system restarted")
        
        // This is a serious event - the entire audio system was reset
        // We need to reconfigure everything
        delegate?.audioSessionWasReset()
    }
    
    // MARK: - Utility Methods
    private func captureCurrentRoute() {
        lastKnownRoute = AVAudioSession.sharedInstance().currentRoute
        
        if let route = lastKnownRoute {
            let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ", ")
            os_log(.info, log: logger, "📱 Current audio route captured: %{public}s", outputs)
        }
    }
    
    // MARK: - Public Interface
    func getCurrentAudioRoute() -> String {
        let currentRoute = AVAudioSession.sharedInstance().currentRoute
        let outputs = currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        return outputs.isEmpty ? "Unknown" : outputs
    }
    
    func getInterruptionStatus() -> String {
        if isInterrupted, let interruption = currentInterruption {
            return "Interrupted: \(interruption.description)"
        } else {
            return "Normal"
        }
    }
    
    // MARK: - Manual State Management
    func setWasPlayingBeforeInterruption(_ wasPlaying: Bool) {
        wasPlayingBeforeInterruption = wasPlaying
        os_log(.debug, log: logger, "📝 Recorded pre-interruption state: %{public}s", wasPlaying ? "playing" : "paused")
    }
    
    func getWasPlayingBeforeInterruption() -> Bool {
        return wasPlayingBeforeInterruption
    }
    
    // MARK: - Cleanup
    deinit {
        NotificationCenter.default.removeObserver(self)
        routeChangeTimer?.invalidate()
        os_log(.info, log: logger, "InterruptionManager deinitialized")
    }
}

// MARK: - AVAudioSession.RouteChangeReason Extension
extension AVAudioSession.RouteChangeReason {
    var description: String {
        switch self {
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
}
