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
    private var currentSyncInterval: TimeInterval = 10.0
    
    // MARK: - Background Strategy Integration
    private weak var connectionManager: SlimProtoConnectionManager?
    
    // MARK: - Network Task Management
    private var currentSyncTask: URLSessionDataTask?
    
    // MARK: - Constants
    private let maxConsecutiveFailures = 3
    private let minSyncInterval: TimeInterval = 5.0
    private let maxSyncInterval: TimeInterval = 60.0
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
        // Use connection manager's background strategy if available
        if let connectionManager = connectionManager {
            currentSyncInterval = connectionManager.backgroundConnectionStrategy.statusInterval
        } else {
            // Fallback to conservative background interval
            currentSyncInterval = 30.0
        }
        
        restartSyncTimer()
    }
    
    private func adjustSyncIntervalForForeground() {
        // Use connection manager's strategy or default to 10 seconds
        if let connectionManager = connectionManager {
            let strategy = connectionManager.backgroundConnectionStrategy
            currentSyncInterval = strategy == .normal ? 10.0 : strategy.statusInterval
        } else {
            currentSyncInterval = 10.0
        }
        
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
        guard !settings.serverHost.isEmpty else {
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
        guard !settings.serverHost.isEmpty else {
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
        let webPort = settings.serverWebPort
        let host = settings.serverHost
        guard let url = URL(string: "http://\(host):\(webPort)/jsonrpc.js") else {
            handleSyncFailure(ServerTimeSyncError.invalidURL)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        // Update state
        lastServerTime = currentTime
        lastServerDuration = duration
        lastServerIsPlaying = isPlaying
        isServerTimeAvailable = true
        lastSuccessfulSync = Date()
        timeSinceLastUpdate = 0
        
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
        
        // Log success
        os_log(.info, log: logger, "✅ Server time updated: %.2f/%.2f (%{public}s)",
               currentTime, duration, isPlaying ? "playing" : "paused")
        
        // Notify of connection restoration if we had failures
        if hadFailures {
            delegate?.serverTimeConnectionRestored()
            os_log(.info, log: logger, "🔄 Server time connection restored after %d failures", hadFailures)
        }
    }
    
    private func handleSyncFailure(_ error: Error) {
        consecutiveFailures += 1
        isServerTimeAvailable = (consecutiveFailures <= maxConsecutiveFailures)
        
        os_log(.error, log: logger, "❌ Server time sync failed (%d/%d): %{public}s",
               consecutiveFailures, maxConsecutiveFailures, error.localizedDescription)
        
        // Adjust sync interval for failures
        adjustSyncIntervalForFailures()
        restartSyncTimer()
        
        // Notify delegate
        delegate?.serverTimeFetchFailed(error: error)
        
        // If we've exceeded max failures, stop considering server time available
        if consecutiveFailures > maxConsecutiveFailures {
            os_log(.error, log: logger, "🚨 Server time unavailable after %d consecutive failures", consecutiveFailures)
        }
    }
    
    // MARK: - Time Interpolation
    func getCurrentInterpolatedTime() -> (time: Double, isPlaying: Bool, isServerTime: Bool) {
        guard isServerTimeAvailable,
              let lastSync = lastSuccessfulSync else {
            return (time: 0.0, isPlaying: false, isServerTime: false)
        }
        
        let timeSinceSync = Date().timeIntervalSince(lastSync)
        timeSinceLastUpdate = timeSinceSync
        
        // If too much time has passed since last sync, don't interpolate
        guard timeSinceSync < currentSyncInterval * 2 else {
            os_log(.error, log: logger, "⚠️ Server time too stale (%.1fs since last sync)", timeSinceSync)
            return (time: lastServerTime, isPlaying: lastServerIsPlaying, isServerTime: false)
        }
        
        // Interpolate time if playing
        let interpolatedTime: Double
        if lastServerIsPlaying {
            interpolatedTime = lastServerTime + timeSinceSync
        } else {
            interpolatedTime = lastServerTime
        }
        
        // Clamp to duration if we have it
        let clampedTime: Double
        if lastServerDuration > 0 {
            clampedTime = min(interpolatedTime, lastServerDuration)
        } else {
            clampedTime = max(0, interpolatedTime)
        }
        
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
