// File: ServerTimeSynchronizer.swift
// Fetches playback time from Lyrion server via JSON-RPC for accurate lock screen display
import Foundation
import os.log
import UIKit

protocol ServerTimeSynchronizerDelegate: AnyObject {
    func serverTimeDidUpdate(currentTime: Double, duration: Double, isPlaying: Bool)
    func serverTimeFetchFailed(error: Error)
    func serverTimeConnectionRestored()
}

class ServerTimeSynchronizer: ObservableObject {
    
    // MARK: - Dependencies
    private let settings = SettingsManager.shared
    private let logger = OSLog(subsystem: "com.lmsstream", category: "ServerTimeSynchronizer")
    
    // MARK: - Published State
    @Published var isServerTimeAvailable: Bool = false
    @Published var lastServerTime: Double = 0.0
    @Published var lastServerDuration: Double = 0.0
    @Published var lastServerIsPlaying: Bool = false
    @Published var timeSinceLastUpdate: TimeInterval = 0
    
    // MARK: - Delegation
    weak var delegate: ServerTimeSynchronizerDelegate?
    
    // MARK: - Sync State
    private var syncTimer: Timer?
    private var lastSuccessfulSync: Date?
    private var consecutiveFailures: Int = 0
    private var isInBackground: Bool = false
    private var currentSyncInterval: TimeInterval = 5.0
    private var updatesPaused: Bool = false  // ADD: For pausing updates during recovery
    
    // MARK: - Background Strategy Integration
    private weak var connectionManager: SlimProtoConnectionManager?
    
    // MARK: - Network Task Management
    private var currentSyncTask: URLSessionDataTask?
    
    // MARK: - Constants
    private let maxConsecutiveFailures = 3
    private let minSyncInterval: TimeInterval = 3.0      // CHANGED from 5.0
    private let maxSyncInterval: TimeInterval = 30.0     // CHANGED from 60.0
    private let requestTimeout: TimeInterval = 5.0
    
    // MARK: - Initialization
    init(connectionManager: SlimProtoConnectionManager? = nil) {
        self.connectionManager = connectionManager
        setupBackgroundObservers()
        os_log(.info, log: logger, "ServerTimeSynchronizer initialized")
    }
    
    // MARK: - Background Observers
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
    }
    
    @objc private func appDidEnterBackground() {
        isInBackground = true
        adjustSyncIntervalForBackground()
        os_log(.info, log: logger, "📱 Adjusted sync interval for background: %.0f seconds", currentSyncInterval)
    }
    
    @objc private func appWillEnterForeground() {
        isInBackground = false
        adjustSyncIntervalForForeground()
        os_log(.info, log: logger, "📱 Adjusted sync interval for foreground: %.0f seconds", currentSyncInterval)
        
        // Immediate sync when returning to foreground
        performImmediateSync()
    }
    
    // MARK: - Sync Interval Management
    private func adjustSyncIntervalForBackground() {
        // Simplified: Use consistent 15-second interval for background
        currentSyncInterval = 15.0
        restartSyncTimer()
    }
    
    private func adjustSyncIntervalForForeground() {
        // Simplified: Use consistent 10-second interval for foreground
        currentSyncInterval = 10.0
        restartSyncTimer()
    }
    
    private func adjustSyncIntervalForFailures() {
        // Exponentially back off on failures, but cap it
        let failureMultiplier = min(Double(consecutiveFailures), 4.0)
        let baseInterval = isInBackground ? 30.0 : 10.0
        currentSyncInterval = min(baseInterval * (1.0 + failureMultiplier), maxSyncInterval)
        
        os_log(.info, log: logger, "⚠️ Adjusted sync interval for %d failures: %.0f seconds",
               consecutiveFailures, currentSyncInterval)
    }
    
    // MARK: - Public Interface
    func startSyncing() {
        guard !settings.activeServerHost.isEmpty else {
            os_log(.error, log: logger, "Cannot start syncing - no server configured")
            return
        }
        
        os_log(.info, log: logger, "🔄 Starting server time synchronization")
        
        // Initial sync
        performImmediateSync()
        
        // Start timer
        restartSyncTimer()
    }
    
    func stopSyncing() {
        os_log(.info, log: logger, "⏹️ Stopping server time synchronization")
        
        stopSyncTimer()
        cancelCurrentSyncTask()
        
        isServerTimeAvailable = false
        consecutiveFailures = 0
        lastSuccessfulSync = nil
    }
    
    // MARK: - Pause/Resume Updates (for recovery scenarios)
    func pauseUpdates() {
        os_log(.info, log: logger, "⏸️ Pausing server time updates")
        updatesPaused = true
        stopSyncTimer()  // Stop the timer but keep other state
    }
    
    func resumeUpdates() {
        os_log(.info, log: logger, "▶️ Resuming server time updates")
        updatesPaused = false
        
        // Only restart if we were syncing before
        if isServerTimeAvailable || lastSuccessfulSync != nil {
            restartSyncTimer()
        }
    }
    
    func performImmediateSync() {
        // Cancel any existing sync
        cancelCurrentSyncTask()
        
        // Perform new sync
        fetchServerTime()
    }
    
    // MARK: - Timer Management
    private func restartSyncTimer() {
        stopSyncTimer()
        
        syncTimer = Timer.scheduledTimer(withTimeInterval: currentSyncInterval, repeats: true) { [weak self] _ in
            self?.fetchServerTime()
        }
        
        os_log(.debug, log: logger, "🔄 Sync timer started with %.0f second interval", currentSyncInterval)
    }
    
    private func stopSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
    }
    
    private func cancelCurrentSyncTask() {
        currentSyncTask?.cancel()
        currentSyncTask = nil
    }
    
    // MARK: - Server Time Fetching
    private func fetchServerTime() {
        // Don't fetch if we don't have a configured server
        guard !settings.activeServerHost.isEmpty else {
            handleSyncFailure(ServerTimeSyncError.noServerConfigured)
            return
        }
        
        // Cancel any existing request
        cancelCurrentSyncTask()
        
        let playerID = settings.playerMACAddress
        
        // Create JSON-RPC request for player status
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                [
                    "status", "-", "1",
                    "tags:u,d,t"  // u=url, d=duration, t=title - minimal tags for performance
                ]
            ]
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            handleSyncFailure(ServerTimeSyncError.jsonSerializationFailed)
            return
        }
        
        // Create request
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        guard let url = URL(string: "http://\(host):\(webPort)/jsonrpc.js") else {
            handleSyncFailure(ServerTimeSyncError.invalidURL)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = requestTimeout
        
        // Perform request
        currentSyncTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleSyncResponse(data: data, response: response, error: error)
            }
        }
        
        currentSyncTask?.resume()
        
        os_log(.debug, log: logger, "🌐 Fetching server time from %{public}s:%d", host, webPort)
    }
    
    // MARK: - Response Handling
    private func handleSyncResponse(data: Data?, response: URLResponse?, error: Error?) {
        currentSyncTask = nil
        
        // Check for network errors
        if let error = error {
            if (error as NSError).code != NSURLErrorCancelled {
                handleSyncFailure(error)
            }
            return
        }
        
        // Check for HTTP errors
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode >= 400 {
            handleSyncFailure(ServerTimeSyncError.httpError(httpResponse.statusCode))
            return
        }
        
        // Parse response
        guard let data = data else {
            handleSyncFailure(ServerTimeSyncError.noDataReceived)
            return
        }
        
        parseServerTimeResponse(data: data)
    }
    
    private func parseServerTimeResponse(data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any] else {
                handleSyncFailure(ServerTimeSyncError.invalidJSONStructure)
                return
            }
            
            // Extract timing information
            let time = result["time"] as? Double ?? 0.0
            let duration = result["duration"] as? Double ?? 0.0
            let mode = result["mode"] as? String ?? "stop"
            let isPlaying = (mode == "play")
            
            // Validate the data
            guard time >= 0 && time.isFinite else {
                os_log(.error, log: logger, "❌ Invalid time value from server: %.2f", time)
                handleSyncFailure(ServerTimeSyncError.invalidTimeValue)
                return
            }
            
            // Update state
            handleSyncSuccess(currentTime: time, duration: duration, isPlaying: isPlaying)
            
        } catch {
            handleSyncFailure(ServerTimeSyncError.jsonParsingFailed(error))
        }
    }
    
    // MARK: - Success/Failure Handling
    private func handleSyncSuccess(currentTime: Double, duration: Double, isPlaying: Bool) {
        // CRITICAL: Don't update if updates are paused (during recovery)
        if updatesPaused {
            os_log(.debug, log: logger, "🔒 Server time updates paused - ignoring sync result: %.2f", currentTime)
            return
        }
        
        // Update state
        let oldTime = lastServerTime
        let oldPlaying = lastServerIsPlaying
        
        // CRITICAL FIX: Always update to the actual server time, don't preserve old values
        lastServerTime = currentTime
        lastServerDuration = duration
        lastServerIsPlaying = isPlaying
        isServerTimeAvailable = true
        lastSuccessfulSync = Date()
        timeSinceLastUpdate = 0
        
        // ENHANCED LOGGING: Show when server time changes significantly
        let timeDifference = abs(currentTime - oldTime)
        if timeDifference > 2.0 {
            os_log(.info, log: logger, "📡 MAJOR SERVER TIME UPDATE: %.2f → %.2f (diff: %.2f), playing=%{public}s → %{public}s",
                   oldTime, currentTime, timeDifference, oldPlaying ? "YES" : "NO", isPlaying ? "YES" : "NO")
        } else {
            os_log(.debug, log: logger, "📡 Server time update: %.2f (playing: %{public}s)",
                   currentTime, isPlaying ? "YES" : "NO")
        }
        
        // Reset failure count
        let hadFailures = consecutiveFailures > 0
        consecutiveFailures = 0
        
        // Restore normal sync interval if we had failures
        if hadFailures {
            if isInBackground {
                adjustSyncIntervalForBackground()
            } else {
                adjustSyncIntervalForForeground()
            }
        }
        
        // Notify delegate
        delegate?.serverTimeDidUpdate(currentTime: currentTime, duration: duration, isPlaying: isPlaying)
        
        if hadFailures {
            delegate?.serverTimeConnectionRestored()
            os_log(.info, log: logger, "🔄 Server time connection restored after %d failures", hadFailures)
        }
    }
    
    func forceImmediateSync() {
        os_log(.info, log: logger, "🔄 Forcing immediate server time sync to get current position")
        
        // CRITICAL: Force sync even if updates are paused (for position saving)
        let wasPaused = updatesPaused
        updatesPaused = false
        
        // Cancel any existing sync
        cancelCurrentSyncTask()
        
        // Perform immediate sync
        fetchServerTime()
        
        // Restore pause state after a brief delay to allow sync to complete
        if wasPaused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updatesPaused = true
                os_log(.debug, log: self.logger, "🔒 Restored pause state after force sync")
            }
        }
    }
    
    private func handleSyncFailure(_ error: Error) {
        consecutiveFailures += 1
        
        // DON'T mark server time as unavailable due to temporary failures
        // Only mark unavailable if we have MANY consecutive failures (20+)
        isServerTimeAvailable = (consecutiveFailures <= 20)  // Was 3, now 20
        
        os_log(.info, log: logger, "📡 Server time sync failed (%d/20): %{public}s - still trusting server time",
               consecutiveFailures, error.localizedDescription)
        
        // Adjust sync interval for failures but keep trying
        adjustSyncIntervalForFailures()
        restartSyncTimer()
        
        // Only notify delegate of "real" failures after many attempts
        if consecutiveFailures > 10 {
            delegate?.serverTimeFetchFailed(error: error)
        }
        
        // Don't mark as unavailable unless we're really having problems
        if consecutiveFailures > 20 {
            os_log(.error, log: logger, "🚨 Server time marked unavailable after %d consecutive failures", consecutiveFailures)
        }
    }
    
    func updatePlaybackState(isPlaying: Bool) {
        // ONLY update the playing state - never overwrite server time with audio time
        lastServerIsPlaying = isPlaying
        
        os_log(.info, log: logger, "🔄 Playback state updated: playing=%{public}s, server time preserved: %.2f",
               isPlaying ? "YES" : "NO", lastServerTime)
    }
    
    func updateFromSlimProtoPosition(_ position: Double, isPlaying: Bool) {
        // CRITICAL: Update our stored server time with the actual server position
        lastServerTime = position
        lastServerIsPlaying = isPlaying
        lastSuccessfulSync = Date()
        timeSinceLastUpdate = 0
        isServerTimeAvailable = true
        
        os_log(.info, log: logger, "📡 SLIMPROTO SERVER UPDATE: %.2f (playing: %{public}s) - overriding previous server time",
               position, isPlaying ? "YES" : "NO")
        
        // Reset consecutive failures since we got valid data
        consecutiveFailures = 0
        
        // Notify delegate of the server update
        delegate?.serverTimeDidUpdate(currentTime: position, duration: lastServerDuration, isPlaying: isPlaying)
    }

    
    // MARK: - Time Interpolation
    func getCurrentInterpolatedTime() -> (time: Double, isPlaying: Bool, isServerTime: Bool) {
        // If we have ANY server time data, use it - don't be picky about "staleness"
        guard lastServerTime > 0, let lastSync = lastSuccessfulSync else {
           // os_log(.debug, log: logger, "🔒 NO SERVER DATA - returning 0.0")
            return (time: 0.0, isPlaying: false, isServerTime: false)
        }
        
        let timeSinceSync = Date().timeIntervalSince(lastSync)
        timeSinceLastUpdate = timeSinceSync
        
        // MUCH MORE LENIENT: Only invalidate server time if it's REALLY old (10 minutes)
        let maxStaleTime: TimeInterval = 600.0  // 10 minutes instead of 60 seconds
        
        if timeSinceSync > maxStaleTime {
            let shouldLog = timeSinceSync.truncatingRemainder(dividingBy: 3600.0) < 60.0
            if shouldLog {
                os_log(.error, log: logger, "⚠️ Server time REALLY stale (%.0f minutes) - but still trusting it", timeSinceSync / 60.0)
            }
        }
        
        // Interpolate time if playing
        let interpolatedTime: Double
        if lastServerIsPlaying {
            interpolatedTime = lastServerTime + timeSinceSync
           // os_log(.debug, log: logger, "🔒 INTERPOLATING: base=%.2f + elapsed=%.2f = %.2f",
          //         lastServerTime, timeSinceSync, interpolatedTime)
        } else {
            interpolatedTime = lastServerTime
           // os_log(.debug, log: logger, "🔒 NOT INTERPOLATING (paused): returning base=%.2f", lastServerTime)
        }
        
        // Clamp to duration if we have it
        let clampedTime: Double
        if lastServerDuration > 0 {
            clampedTime = min(interpolatedTime, lastServerDuration)
            if clampedTime != interpolatedTime {
              //  os_log(.debug, log: logger, "🔒 CLAMPED to duration: %.2f → %.2f", interpolatedTime, clampedTime)
            }
        } else {
            clampedTime = max(0, interpolatedTime)
        }
        
       // os_log(.debug, log: logger, "🔒 RETURNING: time=%.2f, playing=%{public}s, lastSync=%.1fs ago",
       //        clampedTime, lastServerIsPlaying ? "YES" : "NO", timeSinceSync)
        
        // ALWAYS return isServerTime=true if we have server data
        return (time: clampedTime, isPlaying: lastServerIsPlaying, isServerTime: true)
    }

    // MARK: - Connection Manager Integration
    func setConnectionManager(_ connectionManager: SlimProtoConnectionManager) {
        self.connectionManager = connectionManager
        
        // Adjust current interval based on connection manager state
        if isInBackground {
            adjustSyncIntervalForBackground()
        } else {
            adjustSyncIntervalForForeground()
        }
    }
    
    // MARK: - Debug Information
    var syncStatus: String {
        if isServerTimeAvailable {
            let timeSinceSync = lastSuccessfulSync?.timeIntervalSinceNow ?? 0
            return "Available (last sync: \(Int(abs(timeSinceSync)))s ago)"
        } else {
            return "Unavailable (\(consecutiveFailures) failures)"
        }
    }
    
    // MARK: - Cleanup
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopSyncing()
        os_log(.info, log: logger, "ServerTimeSynchronizer deinitialized")
    }
}

// MARK: - Custom Error Types
enum ServerTimeSyncError: LocalizedError {
    case noServerConfigured
    case invalidURL
    case jsonSerializationFailed
    case jsonParsingFailed(Error)
    case httpError(Int)
    case noDataReceived
    case invalidJSONStructure
    case invalidTimeValue
    
    var errorDescription: String? {
        switch self {
        case .noServerConfigured:
            return "No server configured"
        case .invalidURL:
            return "Invalid server URL"
        case .jsonSerializationFailed:
            return "Failed to create JSON request"
        case .jsonParsingFailed(let error):
            return "JSON parsing failed: \(error.localizedDescription)"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .noDataReceived:
            return "No data received from server"
        case .invalidJSONStructure:
            return "Invalid JSON response structure"
        case .invalidTimeValue:
            return "Invalid time value from server"
        }
    }
}
