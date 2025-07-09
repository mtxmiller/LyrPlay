// File: SimpleTimeTracker.swift
// Material-style time tracking - simple, reliable, proven approach
import Foundation
import os.log

/// Simple time tracker based on LMS Material web interface approach
/// Replaces complex ServerTimeSynchronizer with battle-tested logic
class SimpleTimeTracker: ObservableObject {
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SimpleTimeTracker")
    
    // MARK: - Core State (Material-style)
    private var serverTime: Double = 0.0
    private var serverTimeUpdated: Date?
    private var originalServerTime: Double = 0.0
    private var isPlaying: Bool = false
    private var trackDuration: Double = 0.0
    
    // MARK: - Status
    @Published var isConnected: Bool = false
    @Published var lastUpdateTime: Date?
    
    // MARK: - Initialization
    init() {
        os_log(.info, log: logger, "SimpleTimeTracker initialized with Material-style logic")
    }
    
    // MARK: - Server Time Updates (Material-style)
    
    /// Update time from server (equivalent to Material's server status update)
    func updateFromServer(time: Double, duration: Double = 0.0, playing: Bool) {
        // Store all values atomically (Material approach)
        serverTime = time
        originalServerTime = time
        serverTimeUpdated = Date()
        isPlaying = playing
        
        if duration > 0 {
            trackDuration = duration
        }
        
        // Update published properties
        isConnected = true
        lastUpdateTime = Date()
        
        os_log(.debug, log: logger, "📍 Server time updated: %.2f (duration: %.2f, playing: %{public}s)", 
               time, duration, playing ? "YES" : "NO")
    }
    
    // MARK: - Current Time Calculation (Material-style)
    
    /// Get current interpolated time (Material's core logic)
    func getCurrentTime() -> (time: Double, playing: Bool) {
        guard let updated = serverTimeUpdated else {
            os_log(.debug, log: logger, "🔍 No server time available, returning 0.0")
            return (0.0, false)
        }
        
        if isPlaying {
            let elapsed = Date().timeIntervalSince(updated)
            let interpolatedTime = originalServerTime + elapsed
            
            os_log(.debug, log: logger, "🔍 Interpolated time: %.2f + %.2f = %.2f", 
                   originalServerTime, elapsed, interpolatedTime)
            
            return (interpolatedTime, true)
        } else {
            os_log(.debug, log: logger, "🔍 Not playing, returning stored time: %.2f", serverTime)
            return (serverTime, false)
        }
    }
    
    // MARK: - Convenience Methods
    
    /// Get current time as Double (for backward compatibility)
    func getCurrentTimeDouble() -> Double {
        return getCurrentTime().time
    }
    
    /// Get playing state
    func getPlayingState() -> Bool {
        return getCurrentTime().playing
    }
    
    /// Get track duration
    func getTrackDuration() -> Double {
        return trackDuration
    }
    
    /// Check if time is fresh (within reasonable bounds)
    func isTimeFresh() -> Bool {
        guard let updated = serverTimeUpdated else { return false }
        
        let elapsed = Date().timeIntervalSince(updated)
        return elapsed < 30.0 // Fresh if less than 30 seconds old
    }
    
    // MARK: - State Management
    
    /// Mark as disconnected (stops interpolation)
    func markDisconnected() {
        isConnected = false
        os_log(.info, log: logger, "🔌 Marked as disconnected")
    }
    
    /// Reset all state
    func reset() {
        serverTime = 0.0
        serverTimeUpdated = nil
        originalServerTime = 0.0
        isPlaying = false
        trackDuration = 0.0
        isConnected = false
        lastUpdateTime = nil
        
        os_log(.info, log: logger, "🔄 Reset all time tracking state")
    }
    
    // MARK: - Debug Information
    
    /// Get debug info string
    func getDebugInfo() -> String {
        let (currentTime, playing) = getCurrentTime()
        let freshness = isTimeFresh() ? "Fresh" : "Stale"
        
        return """
        Time: \(String(format: "%.2f", currentTime))s
        Playing: \(playing ? "Yes" : "No")
        Duration: \(String(format: "%.2f", trackDuration))s
        Status: \(freshness)
        Connected: \(isConnected ? "Yes" : "No")
        """
    }
    
    // MARK: - Cleanup
    deinit {
        os_log(.info, log: logger, "SimpleTimeTracker deinitialized")
    }
}