// File: SimpleTimeTracker.swift
// Material-style time tracking - simple, reliable, proven approach
import Foundation
import os.log

/// Simple time tracker based on LMS Material web interface approach
/// Replaces complex ServerTimeSynchronizer with battle-tested logic
class SimpleTimeTracker {
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SimpleTimeTracker")
    
    // MARK: - Core State (Material-style)
    private var serverTime: Double = 0.0
    private var serverTimeUpdated: Date?
    private var originalServerTime: Double = 0.0
    private var isPlaying: Bool = false
    private var trackDuration: Double = 0.0

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

        // Too spammy - uncomment only for debugging server time updates
        // os_log(.debug, log: logger, "📍 Server time updated: %.2f (duration: %.2f, playing: %{public}s)",
        //        time, duration, playing ? "YES" : "NO")
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

            // Too spammy - uncomment only for debugging time interpolation
            // os_log(.debug, log: logger, "🔍 Interpolated time: %.2f (server: %.2f + elapsed: %.2f)", interpolatedTime, originalServerTime, elapsed)

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

    /// Get track duration
    func getTrackDuration() -> Double {
        return trackDuration
    }

    // MARK: - Cleanup
    deinit {
        os_log(.info, log: logger, "SimpleTimeTracker deinitialized")
    }
}