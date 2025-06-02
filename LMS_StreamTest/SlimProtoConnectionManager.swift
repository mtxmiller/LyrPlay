// File: SlimProtoConnectionManager.swift
// Phase 2: Dedicated background/foreground and connection lifecycle management
import Foundation
import UIKit
import os.log

protocol SlimProtoConnectionManagerDelegate: AnyObject {
    func connectionManagerShouldReconnect()
    func connectionManagerDidEnterBackground()
    func connectionManagerDidEnterForeground()
}

class SlimProtoConnectionManager: ObservableObject {
    
    // MARK: - Dependencies
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoConnectionManager")
    
    // MARK: - State
    @Published var connectionState: ConnectionState = .disconnected
    @Published var isInBackground: Bool = false
    
    // MARK: - Delegation
    weak var delegate: SlimProtoConnectionManagerDelegate?
    
    // MARK: - Background Task Management
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    // MARK: - Reconnection Logic
    private var reconnectionTimer: Timer?
    private var reconnectionAttempts: Int = 0
    private let maxReconnectionAttempts: Int = 5
    private let baseReconnectionDelay: TimeInterval = 2.0
    
    // MARK: - Connection State
    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed
        
        var displayName: String {
            switch self {
            case .disconnected: return "Disconnected"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .reconnecting: return "Reconnecting"
            case .failed: return "Failed"
            }
        }
        
        var isConnected: Bool {
            return self == .connected
        }
    }
    
    // MARK: - Initialization
    init() {
        setupBackgroundObservers()
        os_log(.info, log: logger, "SlimProtoConnectionManager initialized")
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
        
        os_log(.info, log: logger, "✅ Background observers configured")
    }
    
    @objc private func appDidEnterBackground() {
        os_log(.info, log: logger, "📱 App entering background")
        isInBackground = true
        
        // Start background task to maintain connection
        startBackgroundTask()
        
        // Notify delegate for any background-specific handling
        delegate?.connectionManagerDidEnterBackground()
        
        os_log(.info, log: logger, "Background transition complete")
    }
    
    @objc private func appWillEnterForeground() {
        os_log(.info, log: logger, "📱 App entering foreground")
        isInBackground = false
        
        // End background task
        stopBackgroundTask()
        
        // Notify delegate
        delegate?.connectionManagerDidEnterForeground()
        
        os_log(.info, log: logger, "Foreground transition complete")
    }
    
    @objc private func appDidBecomeActive() {
        os_log(.info, log: logger, "📱 App became active")
        
        // Check if we need to reconnect after coming back to foreground
        if connectionState == .disconnected || connectionState == .failed {
            os_log(.info, log: logger, "App became active while disconnected - attempting reconnection")
            attemptReconnection()
        }
    }
    
    // MARK: - Background Task Management
    private func startBackgroundTask() {
        guard backgroundTaskID == .invalid else {
            os_log(.info, log: logger, "Background task already running")
            return
        }
        
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SlimProtoConnection") { [weak self] in
            os_log(.error, log: self?.logger ?? OSLog.disabled, "⏰ Background task expiring")
            self?.stopBackgroundTask()
        }
        
        if backgroundTaskID != .invalid {
            os_log(.info, log: logger, "🎯 Background task started (ID: %{public}d)", backgroundTaskID.rawValue)
        } else {
            os_log(.error, log: logger, "❌ Failed to start background task")
        }
    }
    
    private func stopBackgroundTask() {
        guard backgroundTaskID != .invalid else {
            return
        }
        
        os_log(.info, log: logger, "🏁 Ending background task (ID: %{public}d)", backgroundTaskID.rawValue)
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
    
    // MARK: - Connection State Management
    func didConnect() {
        os_log(.info, log: logger, "✅ Connection established")
        connectionState = .connected
        reconnectionAttempts = 0
        stopReconnectionTimer()
    }
    
    func didDisconnect(error: Error?) {
        let wasConnected = connectionState.isConnected
        
        if let error = error {
            os_log(.error, log: logger, "❌ Disconnected with error: %{public}s", error.localizedDescription)
            connectionState = .failed
        } else {
            os_log(.info, log: logger, "🔌 Disconnected gracefully")
            connectionState = .disconnected
        }
        
        // Only attempt reconnection if we were previously connected and have an error
        if wasConnected && error != nil {
            attemptReconnection()
        } else if error != nil {
            // Connection failed during initial connection
            scheduleReconnectionIfNeeded()
        }
    }
    
    func willConnect() {
        os_log(.info, log: logger, "🔄 Connection attempt starting")
        if connectionState == .disconnected || connectionState == .failed {
            connectionState = .connecting
        } else {
            connectionState = .reconnecting
        }
    }
    
    // MARK: - Reconnection Logic
    private func attemptReconnection() {
        guard shouldAttemptReconnection() else {
            os_log(.info, log: logger, "Skipping reconnection attempt")
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
        os_log(.info, log: logger, "⏰ Scheduling reconnection in %.1f seconds", delay)
        
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
        
        // Don't reconnect if app is in background and we've been disconnected for a while
        if isInBackground && reconnectionAttempts > 2 {
            os_log(.info, log: logger, "Limiting background reconnection attempts")
            return false
        }
        
        return true
    }
    
    private func calculateReconnectionDelay() -> TimeInterval {
        // Exponential backoff with jitter
        let exponentialDelay = baseReconnectionDelay * pow(2.0, Double(reconnectionAttempts))
        let maxDelay: TimeInterval = 30.0
        let delay = min(exponentialDelay, maxDelay)
        
        // Add some jitter to avoid thundering herd
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
        resetReconnectionAttempts()
        attemptReconnection()
    }
    
    // MARK: - Background Strategy
    var backgroundConnectionStrategy: BackgroundStrategy {
        if isInBackground {
            return .minimal
        } else {
            return .normal
        }
    }
    
    enum BackgroundStrategy {
        case normal    // Full functionality
        case minimal   // Reduced activity, longer intervals
        case suspended // Minimal activity only
    }
    
    // MARK: - Cleanup
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopReconnectionTimer()
        stopBackgroundTask()
        os_log(.info, log: logger, "SlimProtoConnectionManager deinitialized")
    }
}
