// File: SlimProtoConnectionManager.swift
// Phase 2: Enhanced background handling with network monitoring and smart reconnection
import Foundation
import UIKit
import Network
import os.log

protocol SlimProtoConnectionManagerDelegate: AnyObject {
    func connectionManagerShouldReconnect()
    func connectionManagerDidEnterBackground()
    func connectionManagerDidEnterForeground()
    func connectionManagerNetworkDidChange(isAvailable: Bool, isExpensive: Bool)
    func connectionManagerShouldCheckHealth()
    func connectionManagerShouldStorePosition()
    func connectionManagerDidReconnectAfterTimeout()
}

class SlimProtoConnectionManager: ObservableObject {
    
    // MARK: - Dependencies
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoConnectionManager")
    
    // MARK: - Published State
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isInBackground: Bool = false
    @Published var networkStatus: NetworkStatus = .unknown
    @Published var backgroundTimeRemaining: TimeInterval = 0
    
    // MARK: - Delegation
    weak var delegate: SlimProtoConnectionManagerDelegate?
    
    // MARK: - Network Monitoring
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.lmsstream.network")
    private var isNetworkAvailable = false
    private var isNetworkExpensive = false
    
    // MARK: - Background Task Management
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundTimer: Timer?
    private var backgroundStartTime: Date?
    
    // MARK: - Reconnection Logic
    private var reconnectionTimer: Timer?
    private var reconnectionAttempts: Int = 0
    private let maxReconnectionAttempts: Int = 8  // Increased for better persistence
    private let baseReconnectionDelay: TimeInterval = 2.0
    private var lastSuccessfulConnection: Date?
    private var lastDisconnectionReason: DisconnectionReason = .unknown
    
    private var wasConnectedBeforeTimeout: Bool = false
    private var disconnectionDuration: TimeInterval = 0
    
    
    // MARK: - Health Monitoring
    private var healthCheckTimer: Timer?
    private var lastHeartbeatResponse: Date?
    private let heartbeatTimeout: TimeInterval = 30.0
    
    // MARK: - Connection State
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed
        case networkUnavailable
        
        var displayName: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .reconnecting: return "Reconnecting"
            case .failed: return "Failed"
            case .networkUnavailable: return "No Network"
            }
        }
        
        var isConnected: Bool {
            return self == .connected
        }
        
        var canAttemptConnection: Bool {
            switch self {
            case .disconnected, .failed, .networkUnavailable:
                return true
            default:
                return false
            }
        }
    }
    
    // MARK: - Network Status
    enum NetworkStatus {
        case unknown
        case unavailable
        case wifi
        case cellular
        case wired
        
        var displayName: String {
            switch self {
            case .unknown: return "Unknown"
            case .unavailable: return "No Network"
            case .wifi: return "Wi-Fi"
            case .cellular: return "Cellular"
            case .wired: return "Wired"
            }
        }
        
        var isAvailable: Bool {
            return self != .unavailable && self != .unknown
        }
    }
    
    // MARK: - Disconnection Reason
    enum DisconnectionReason {
        case unknown
        case networkLost
        case serverError
        case appBackgrounded
        case userInitiated
        case timeout
        
        var shouldAutoReconnect: Bool {
            switch self {
            case .networkLost, .serverError, .appBackgrounded, .timeout:
                return true
            case .userInitiated:
                return false
            case .unknown:
                return true
            }
        }
    }
    
    // MARK: - Initialization
    init() {
        setupBackgroundObservers()
        startNetworkMonitoring()
        os_log(.info, log: logger, "Enhanced SlimProtoConnectionManager initialized")
    }
    
    // MARK: - Network Monitoring
    private func startNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.handleNetworkPathUpdate(path)
            }
        }
        networkMonitor.start(queue: networkQueue)
        os_log(.info, log: logger, "✅ Network monitoring started")
    }
    
    private func handleNetworkPathUpdate(_ path: NWPath) {
        let wasAvailable = isNetworkAvailable
        isNetworkAvailable = path.status == .satisfied
        isNetworkExpensive = path.isExpensive
        
        // Update network status
        if path.status == .satisfied {
            if path.usesInterfaceType(.wifi) {
                networkStatus = .wifi
            } else if path.usesInterfaceType(.cellular) {
                networkStatus = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                networkStatus = .wired
            } else {
                networkStatus = .wifi // Default assumption
            }
        } else {
            networkStatus = .unavailable
        }
        
        os_log(.info, log: logger, "🌐 Network status: %{public}s (expensive: %{public}s)",
               networkStatus.displayName, isNetworkExpensive ? "YES" : "NO")
        
        // Handle network state changes
        if !wasAvailable && isNetworkAvailable {
            handleNetworkRestored()
        } else if wasAvailable && !isNetworkAvailable {
            handleNetworkLost()
        }
        
        // Notify delegate
        delegate?.connectionManagerNetworkDidChange(isAvailable: isNetworkAvailable, isExpensive: isNetworkExpensive)
    }
    
    private func handleNetworkRestored() {
        os_log(.info, log: logger, "🌐 Network restored")
        
        // Update connection state if we were disconnected due to network
        if connectionState == .networkUnavailable {
            connectionState = .disconnected
            
            // Attempt reconnection if we were previously connected
            if lastSuccessfulConnection != nil {
                os_log(.info, log: logger, "🔄 Network restored - attempting reconnection")
                attemptReconnection()
            }
        }
    }
    
    private func handleNetworkLost() {
        os_log(.error, log: logger, "🌐 Network lost")
        lastDisconnectionReason = .networkLost
        
        if connectionState.isConnected {
            connectionState = .networkUnavailable
        }
    }
    
    // MARK: - Background/Foreground Handling
    private func setupBackgroundObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        os_log(.info, log: logger, "✅ Enhanced background observers configured")
    }
    
    @objc private func appDidEnterBackground() {
        os_log(.info, log: logger, "📱 App entering background")
        isInBackground = true
        backgroundStartTime = Date()
        lastDisconnectionReason = .appBackgrounded
        
        // Start enhanced background task
        startEnhancedBackgroundTask()
        
        // Start background timer to track remaining time
        startBackgroundTimer()
        
        // Adjust health check frequency for background
        if connectionState.isConnected {
            startHealthMonitoring(interval: 30.0) // Less frequent in background
        }
        
        // Notify delegate
        delegate?.connectionManagerDidEnterBackground()
        
        os_log(.info, log: logger, "📱 Background transition complete")
    }
    
    @objc private func appWillEnterForeground() {
        os_log(.info, log: logger, "📱 App entering foreground")
        isInBackground = false
        
        // End background task and timer
        stopEnhancedBackgroundTask()
        stopBackgroundTimer()
        
        // Resume normal health check frequency
        if connectionState.isConnected {
            startHealthMonitoring(interval: 15.0) // More frequent in foreground
        }
        
        // Check connection health immediately
        if connectionState.isConnected {
            delegate?.connectionManagerShouldCheckHealth()
        }
        
        // Notify delegate
        delegate?.connectionManagerDidEnterForeground()
        
        os_log(.info, log: logger, "📱 Foreground transition complete")
    }
    
    @objc private func appDidBecomeActive() {
        os_log(.info, log: logger, "📱 App became active")
        
        // Check if we need to reconnect after coming back to foreground
        if !isNetworkAvailable {
            os_log(.info, log: logger, "📱 App became active but network unavailable")
        } else if connectionState.canAttemptConnection {
            os_log(.info, log: logger, "📱 App became active while disconnected - attempting reconnection")
            attemptReconnection()
        }
    }
    
    // MARK: - Enhanced Background Task Management
    private func startEnhancedBackgroundTask() {
        guard backgroundTaskID == .invalid else {
            os_log(.info, log: logger, "Background task already running")
            return
        }
        
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SlimProtoConnectionExtended") { [weak self] in
            os_log(.error, log: self?.logger ?? OSLog.disabled, "⏰ Background task expiring - preparing for suspension")
            self?.prepareForBackgroundSuspension()
            self?.stopEnhancedBackgroundTask()
        }
        
        if backgroundTaskID != .invalid {
            let timeRemaining = UIApplication.shared.backgroundTimeRemaining
            os_log(.info, log: logger, "🎯 Enhanced background task started (ID: %{public}d, time: %.0f sec)",
                   backgroundTaskID.rawValue, timeRemaining)
            backgroundTimeRemaining = timeRemaining
        } else {
            os_log(.error, log: logger, "❌ Failed to start background task")
        }
    }
    
    private func stopEnhancedBackgroundTask() {
        guard backgroundTaskID != .invalid else {
            return
        }
        
        os_log(.info, log: logger, "🏁 Ending enhanced background task (ID: %{public}d)", backgroundTaskID.rawValue)
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
        backgroundTimeRemaining = 0
    }
    
    private func startBackgroundTimer() {
        stopBackgroundTimer()
        
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateBackgroundTimeRemaining()
        }
    }
    
    private func stopBackgroundTimer() {
        backgroundTimer?.invalidate()
        backgroundTimer = nil
    }
    
    private func updateBackgroundTimeRemaining() {
        if isInBackground && backgroundTaskID != .invalid {
            backgroundTimeRemaining = UIApplication.shared.backgroundTimeRemaining
            
            // Log when we're getting close to suspension
            if backgroundTimeRemaining < 30 && backgroundTimeRemaining > 25 {
                // REMOVED: Noisy background time logs - os_log(.error, log: logger, "⏰ Background time running low: %.0f seconds remaining", backgroundTimeRemaining)
            }
        } else {
            backgroundTimeRemaining = 0
        }
    }
    
    private func prepareForBackgroundSuspension() {
        os_log(.info, log: logger, "📱 Background task expiring - disconnecting cleanly")
        
        // Simple disconnect when background task expires
        if connectionState.isConnected {
            lastDisconnectionReason = .appBackgrounded
            // Set state to trigger disconnection in coordinator
            connectionState = .disconnected
        }
        
        // Stop health monitoring to avoid unnecessary activity
        stopHealthMonitoring()
    }
    
    // MARK: - Health Monitoring
    private func startHealthMonitoring(interval: TimeInterval = 15.0) {
        stopHealthMonitoring()
        
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
        
        os_log(.info, log: logger, "💓 Health monitoring started (%.0f sec intervals)", interval)
    }
    
    private func stopHealthMonitoring() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }
    
    private func performHealthCheck() {
        guard connectionState.isConnected else {
            return
        }
        
        // Check if we've received a recent heartbeat response
        if let lastResponse = lastHeartbeatResponse {
            let timeSinceLastResponse = Date().timeIntervalSince(lastResponse)
            
            if timeSinceLastResponse > heartbeatTimeout {
                os_log(.error, log: logger, "💓 Health check failed - no response for %.0f seconds", timeSinceLastResponse)
                handleHealthCheckFailure()
                return
            }
        }
        
        // Request health check from delegate
        delegate?.connectionManagerShouldCheckHealth()
        
        os_log(.debug, log: logger, "💓 Health check requested")
    }
    
    private func handleHealthCheckFailure() {
        os_log(.error, log: logger, "💓 Connection health check failed")
        lastDisconnectionReason = .timeout
        
        // Mark as failed and attempt reconnection
        if connectionState.isConnected {
            connectionState = .failed
            attemptReconnection()
        }
    }
    
    func recordHeartbeatResponse() {
        lastHeartbeatResponse = Date()
    }
    
    // MARK: - Connection State Management
    func didConnect() {
        let wasReconnectionAfterTimeout = wasConnectedBeforeTimeout &&
        connectionState != .connected
        os_log(.info, log: logger, "✅ Connection established")
        connectionState = .connected
        lastSuccessfulConnection = Date()
        reconnectionAttempts = 0
        stopReconnectionTimer()
        
        // Start health monitoring
        let interval = isInBackground ? 30.0 : 15.0
        startHealthMonitoring(interval: interval)
        
        // Record initial heartbeat
        recordHeartbeatResponse()
        
        if wasReconnectionAfterTimeout {
            delegate?.connectionManagerDidReconnectAfterTimeout()
        }
        
        wasConnectedBeforeTimeout = false
    }
    
    func didDisconnect(error: Error?) {
        let wasConnected = connectionState.isConnected
        wasConnectedBeforeTimeout = wasConnected
        
        // Attempt reconnection based on conditions
        if wasConnected && shouldStorePosition(error: error) {
            delegate?.connectionManagerShouldStorePosition()
        }
        
        // Stop health monitoring
        stopHealthMonitoring()
        
        // Determine disconnection reason and set state
        if !isNetworkAvailable {
            connectionState = .networkUnavailable
            lastDisconnectionReason = .networkLost
            os_log(.error, log: logger, "❌ Disconnected - network unavailable")
        } else if let error = error {
            connectionState = .failed
            lastDisconnectionReason = .serverError
            os_log(.error, log: logger, "❌ Disconnected with error: %{public}s", error.localizedDescription)
        } else {
            connectionState = .disconnected
            lastDisconnectionReason = .unknown
            os_log(.info, log: logger, "🔌 Disconnected gracefully")
        }
        

    }
    
    // Add this method to detect timeout scenarios
    private func shouldStorePosition(error: Error?) -> Bool {
        // Store position for any unexpected disconnection during active connection
        // Only skip storage for graceful/intentional disconnections
        if let error = error {
            // Any error during disconnection suggests unexpected loss
            return true
        }
        
        // For graceful disconnections (no error), only store if we had a recent connection
        return lastSuccessfulConnection != nil
    }
    
    func willConnect() {
        os_log(.info, log: logger, "🔄 Connection attempt starting")
        
        if !isNetworkAvailable {
            connectionState = .networkUnavailable
            os_log(.error, log: logger, "🔄 Cannot connect - network unavailable")
            return
        }
        
        if connectionState.canAttemptConnection {
            connectionState = .connecting
        } else {
            connectionState = .reconnecting
        }
    }
    
    // MARK: - Enhanced Reconnection Logic
    private func attemptReconnection() {
        guard shouldAttemptReconnection() else {
            os_log(.info, log: logger, "Skipping reconnection attempt")
            return
        }
        
        guard isNetworkAvailable else {
            os_log(.error, log: logger, "🔄 Cannot reconnect - network unavailable")
            connectionState = .networkUnavailable
            return
        }
        
        reconnectionAttempts += 1
        os_log(.info, log: logger, "🔄 Reconnection attempt %d/%d", reconnectionAttempts, maxReconnectionAttempts)
        
        connectionState = .reconnecting
        delegate?.connectionManagerShouldReconnect()
    }
    
    private func scheduleReconnectionIfNeeded() {
        guard shouldAttemptReconnection() else {
            os_log(.error, log: logger, "❌ Max reconnection attempts reached")
            connectionState = .failed
            return
        }
        
        let delay = calculateReconnectionDelay()
        os_log(.info, log: logger, "⏰ Scheduling reconnection in %.1f seconds (attempt %d)", delay, reconnectionAttempts + 1)
        
        stopReconnectionTimer()
        reconnectionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.attemptReconnection()
        }
    }
    
    private func shouldAttemptReconnection() -> Bool {
        // Don't reconnect if we've exceeded max attempts
        if reconnectionAttempts >= maxReconnectionAttempts {
            return false
        }
        
        // Don't reconnect if network is unavailable
        if !isNetworkAvailable {
            return false
        }
        
        // Don't reconnect if user initiated the disconnection
        if lastDisconnectionReason == .userInitiated {
            return false
        }
        
        // Limit background reconnection attempts to preserve battery
        if isInBackground && reconnectionAttempts > 3 {
            os_log(.info, log: logger, "🔄 Limiting background reconnection attempts")
            return false
        }
        
        // Don't reconnect on expensive networks if we have many failures
        if isNetworkExpensive && reconnectionAttempts > 2 {
            os_log(.info, log: logger, "🔄 Limiting reconnection on expensive network")
            return false
        }
        
        return true
    }
    
    private func calculateReconnectionDelay() -> TimeInterval {
        // Base delay increases with attempts
        let exponentialDelay = baseReconnectionDelay * pow(2.0, Double(reconnectionAttempts))
        
        // Cap the delay based on context
        let maxDelay: TimeInterval = isInBackground ? 60.0 : 30.0
        let delay = min(exponentialDelay, maxDelay)
        
        // Add jitter to avoid thundering herd
        let jitter = Double.random(in: 0.8...1.2)
        return delay * jitter
    }
    
    private func stopReconnectionTimer() {
        reconnectionTimer?.invalidate()
        reconnectionTimer = nil
    }
    
    // MARK: - Manual Control
    func resetReconnectionAttempts() {
        os_log(.info, log: logger, "🔄 Resetting reconnection attempts")
        reconnectionAttempts = 0
        stopReconnectionTimer()
    }
    
    func forceReconnection() {
        os_log(.info, log: logger, "🔄 Forcing reconnection")
        lastDisconnectionReason = .userInitiated // Will be reset on next disconnect
        resetReconnectionAttempts()
        attemptReconnection()
    }
    
    func userInitiatedDisconnection() {
        os_log(.info, log: logger, "🔄 User initiated disconnection")
        lastDisconnectionReason = .userInitiated
        stopReconnectionTimer()
        stopHealthMonitoring()
    }
    
    // MARK: - Background Strategy (Enhanced)
    var backgroundConnectionStrategy: BackgroundStrategy {
        if !isInBackground {
            return .normal
        }
        
        // Check how long we've been in background
        let backgroundDuration = backgroundStartTime?.timeIntervalSinceNow ?? 0
        let absBackgroundDuration = abs(backgroundDuration)
        
        if backgroundTimeRemaining < 30 {
            return .suspended
        } else if absBackgroundDuration > 300 || isNetworkExpensive { // 5 minutes
            return .minimal
        } else {
            return .reduced
        }
    }
    
    enum BackgroundStrategy {
        case normal    // Full functionality
        case reduced   // Slightly reduced activity
        case minimal   // Reduced activity, longer intervals
        case suspended // Minimal activity only
        
        var statusInterval: TimeInterval {
            switch self {
            case .normal: return 10.0
            case .reduced: return 15.0
            case .minimal: return 30.0
            case .suspended: return 60.0
            }
        }
        
        var healthCheckInterval: TimeInterval {
            switch self {
            case .normal: return 15.0
            case .reduced: return 20.0
            case .minimal: return 30.0
            case .suspended: return 60.0
            }
        }
    }
    
    // MARK: - Public Status
    var connectionSummary: String {
        var summary = connectionState.displayName
        
        if networkStatus != .unknown {
            summary += " (\(networkStatus.displayName)"
            if isNetworkExpensive {
                summary += ", expensive"
            }
            summary += ")"
        }
        
        if isInBackground && backgroundTimeRemaining > 0 {
            summary += " - Background: \(Int(backgroundTimeRemaining))s"
        }
        
        return summary
    }
    
    // MARK: - Cleanup
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopReconnectionTimer()
        stopHealthMonitoring()
        stopEnhancedBackgroundTask()
        stopBackgroundTimer()
        networkMonitor.cancel()
        os_log(.info, log: logger, "Enhanced SlimProtoConnectionManager deinitialized")
    }
}
