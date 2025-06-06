// File: SlimProtoCoordinator.swift
// Enhanced with ServerTimeSynchronizer for accurate lock screen timing
import Foundation
import os.log

class SlimProtoCoordinator: ObservableObject {
    
    // MARK: - Components
    private let client: SlimProtoClient
    private let commandHandler: SlimProtoCommandHandler
    private let connectionManager: SlimProtoConnectionManager
    private let audioManager: AudioManager
    private let serverTimeSynchronizer: ServerTimeSynchronizer
    
    // MARK: - Dependencies
    private let settings = SettingsManager.shared
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoCoordinator")
    
    // MARK: - State Management
    private var statusTimer: Timer?
    private var lastStatusSent: Date?
    
    // NEW: Lock screen specific timing
    private var lockScreenUpdateTimer: Timer?
    private var isStreamActive: Bool = false
    
    // MARK: - Initialization
    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        self.client = SlimProtoClient()
        self.commandHandler = SlimProtoCommandHandler()
        self.connectionManager = SlimProtoConnectionManager()
        self.serverTimeSynchronizer = ServerTimeSynchronizer(connectionManager: connectionManager)
        
        setupDelegation()
        setupAudioCallbacks()
        setupServerTimeIntegration()
        
        os_log(.info, log: logger, "SlimProtoCoordinator initialized with ServerTimeSynchronizer")
    }
    
    // MARK: - Setup
    private func setupDelegation() {
        // Connect client to coordinator
        client.delegate = self
        
        // Connect command handler to client and coordinator
        commandHandler.slimProtoClient = client
        commandHandler.delegate = self
        
        // ADD THIS LINE:
        client.commandHandler = commandHandler
        
        // Connect connection manager to coordinator
        connectionManager.delegate = self
    }
    
    private func setupAudioCallbacks() {
        // Set up track ended callback
        audioManager.onTrackEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.commandHandler.notifyTrackEnded()
            }
        }
        
        // Connect audio manager back to coordinator for lock screen support
        audioManager.slimClient = self
    }
    
    private func setupServerTimeIntegration() {
        // Connect ServerTimeSynchronizer to audio manager's NowPlayingManager
        // This will be done when we set the audio manager reference
        os_log(.info, log: logger, "✅ Server time integration configured")
    }
    
    // MARK: - Audio Manager Integration Enhancement
    func setupNowPlayingManagerIntegration() {
        // Use AudioManager's integration method to set up server time sync
        audioManager.setupServerTimeIntegration(with: serverTimeSynchronizer)
        serverTimeSynchronizer.setConnectionManager(connectionManager)
        
        os_log(.info, log: logger, "✅ Server time synchronizer connected via AudioManager")
    }
    
    // MARK: - Public Interface
    func connect() {
        os_log(.info, log: logger, "Starting connection with server time sync...")
        connectionManager.willConnect()
        client.connect()
    }
    
    func disconnect() {
        os_log(.info, log: logger, "User requested disconnection")
        connectionManager.userInitiatedDisconnection()
        stopStatusTimer()
        stopServerTimeSync()
        client.disconnect()
    }
    
    func updateServerSettings(host: String, port: UInt16) {
        client.updateServerSettings(host: host, port: port)
    }
    
    // MARK: - Server Time Sync Management
    private func startServerTimeSync() {
        serverTimeSynchronizer.startSyncing()
        os_log(.info, log: logger, "🔄 Server time synchronization started")
    }
    
    private func stopServerTimeSync() {
        serverTimeSynchronizer.stopSyncing()
        os_log(.info, log: logger, "⏹️ Server time synchronization stopped")
    }
    
    // MARK: - Enhanced Status Timer with Background Awareness
    private func startStatusTimer() {
        stopStatusTimer()
        
        // Get interval from connection manager's background strategy
        let interval = connectionManager.backgroundConnectionStrategy.statusInterval
        
        statusTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sendPeriodicStatus()
        }
        
        // NEW: Also start lock screen timer
        startLockScreenUpdateTimer()
        
        os_log(.info, log: logger, "Status timer started with %.1f second interval (%{public}s strategy)",
               interval, connectionManager.backgroundConnectionStrategy.description)
    }
    
    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
        
        // NEW: Also stop lock screen timer
        stopLockScreenUpdateTimer()
    }
    
    private func startLockScreenUpdateTimer() {
        stopLockScreenUpdateTimer()
        
        // Use a fast timer for lock screen updates (every 1 second)
        // This is separate from server communication
        lockScreenUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateLockScreenTiming()
        }
        
        os_log(.info, log: logger, "🔒 Lock screen update timer started (1 second interval)")
    }
    
    private func stopLockScreenUpdateTimer() {
        lockScreenUpdateTimer?.invalidate()
        lockScreenUpdateTimer = nil
    }
    
    // MARK: - NEW: Lock Screen Timing Updates
    private func updateLockScreenTiming() {
        guard isStreamActive else { return }
        
        // Get current timing from both sources
        let serverTime = serverTimeSynchronizer.getCurrentInterpolatedTime()
        let audioTime = audioManager.getCurrentTime()
        let isPlaying = audioManager.getPlayerState() == "Playing"
        
        // FIXED: Smart time source selection
        let currentTime: Double
        let timeSource: String
        
        if serverTime.isServerTime && serverTime.time > 0.1 {
            // Use server time only if it's valid AND greater than 0.1 seconds
            // (This avoids the stuck-at-zero problem)
            currentTime = serverTime.time
            timeSource = "server"
        } else if audioTime > 0.0 {
            // Use audio time if it's available and positive
            currentTime = audioTime
            timeSource = "audio"
        } else if serverTime.isServerTime {
            // Fallback to server time even if it's zero (better than nothing)
            currentTime = serverTime.time
            timeSource = "server-fallback"
        } else {
            // Last resort: use zero
            currentTime = 0.0
            timeSource = "none"
        }
        
        // Update now playing manager directly (this goes to lock screen)
        let nowPlayingManager = audioManager.getNowPlayingManager()
        nowPlayingManager.updatePlaybackState(isPlaying: isPlaying, currentTime: currentTime)
        
        os_log(.debug, log: logger, "🔒 Lock screen updated - time: %.2f, playing: %{public}s, source: %{public}s (server: %.2f, audio: %.2f)",
               currentTime, isPlaying ? "YES" : "NO", timeSource, serverTime.time, audioTime)
    }
    
    private func sendPeriodicStatus() {
        // Don't send if we just sent one recently (avoid spam)
        if let lastSent = lastStatusSent, Date().timeIntervalSince(lastSent) < 5.0 {
            return
        }
        
        // PHASE 2 FIX: Don't update position from audio manager before sending status
        // Remove these problematic lines:
        // let currentTime = audioManager.getCurrentTime()  // REMOVED
        // let isPlaying = audioManager.getPlayerState() == "Playing"  // REMOVED
        // client.setPlaybackState(isPlaying: isPlaying, position: currentTime)  // REMOVED
        
        // Send appropriate status based on stream state
        if commandHandler.streamState != "Stopped" {
            if commandHandler.streamState == "Paused" {
                client.sendStatus("STMp")  // Pause status when paused
            } else {
                client.sendStatus("STMt")  // Timer status when playing
            }
            lastStatusSent = Date()
            
            // Record heartbeat for health monitoring
            connectionManager.recordHeartbeatResponse()
            
            os_log(.debug, log: logger, "📡 Periodic status sent without position override")
        }
    }
    
    // MARK: - Connection State (Enhanced)
    var connectionState: String {
        return connectionManager.connectionState.displayName
    }
    
    var streamState: String {
        return commandHandler.streamState
    }
    
    var networkStatus: String {
        return connectionManager.networkStatus.displayName
    }
    
    var connectionSummary: String {
        return connectionManager.connectionSummary
    }
    
    var isInBackground: Bool {
        return connectionManager.isInBackground
    }
    
    var backgroundTimeRemaining: TimeInterval {
        return connectionManager.backgroundTimeRemaining
    }
    
    // MARK: - Server Time Debug Info
    var serverTimeStatus: String {
        return serverTimeSynchronizer.syncStatus
    }
    
    var timeSourceInfo: String {
        return audioManager.getTimeSourceInfo()
    }
    
    deinit {
        stopStatusTimer()
        stopServerTimeSync()
        disconnect()
    }
}

// MARK: - SlimProtoClientDelegate
extension SlimProtoCoordinator: SlimProtoClientDelegate {
    
    func slimProtoDidConnect() {
        os_log(.info, log: logger, "✅ Connection established")
        connectionManager.didConnect()
        startStatusTimer()
        
        // Start server time synchronization once connected
        startServerTimeSync()
        
        // Setup NowPlayingManager integration after connection
        setupNowPlayingManagerIntegration()
    }
    
    func slimProtoDidDisconnect(error: Error?) {
        os_log(.info, log: logger, "🔌 Connection lost")
        connectionManager.didDisconnect(error: error)
        stopStatusTimer()
        
        // Stop server time sync when disconnected
        stopServerTimeSync()
    }
    
    func slimProtoDidReceiveCommand(_ command: SlimProtoCommand) {
        // Record that we received a command (shows connection is alive)
        connectionManager.recordHeartbeatResponse()
        
        // Forward to command handler
        commandHandler.processCommand(command)
    }
}

// MARK: - Enhanced SlimProtoConnectionManagerDelegate
extension SlimProtoCoordinator: SlimProtoConnectionManagerDelegate {
    
    func connectionManagerShouldReconnect() {
        os_log(.info, log: logger, "🔄 Connection manager requesting reconnection")
        client.connect()
    }
    
    func connectionManagerDidEnterBackground() {
        os_log(.info, log: logger, "📱 Coordinator handling enhanced background transition")
        
        // Send immediate status to keep connection alive
        if connectionManager.connectionState.isConnected {
            // PHASE 2 FIX: Don't send position data - just report we're alive
            // Remove these problematic lines:
            // let currentTime = audioManager.getCurrentTime()  // REMOVED
            // let isCurrentlyPlaying = audioManager.getPlayerState() == "Playing"  // REMOVED
            // client.setPlaybackState(isPlaying: isCurrentlyPlaying, position: currentTime)  // REMOVED
            
            // Send basic "I'm alive" status without position data
            client.sendStatus("STMt")
            connectionManager.recordHeartbeatResponse()
            
            os_log(.info, log: logger, "📱 Sent background 'alive' status - server maintains position")
        }
        
        // Restart timer with background strategy interval
        if statusTimer != nil {
            startStatusTimer()
        }
        
        // Server time sync will automatically adjust to background intervals
        os_log(.info, log: logger, "📱 Server time sync adjusted for background")
    }
    
    func connectionManagerDidEnterForeground() {
        os_log(.info, log: logger, "📱 Coordinator handling enhanced foreground transition")
        
        // Check if connection is still alive
        if connectionManager.connectionState.isConnected {
            // PHASE 2 FIX: Don't send position data - just report we're alive
            // Remove these problematic lines:
            // let currentTime = audioManager.getCurrentTime()  // REMOVED
            // let isCurrentlyPlaying = audioManager.getPlayerState() == "Playing"  // REMOVED
            // client.setPlaybackState(isPlaying: isCurrentlyPlaying, position: currentTime)  // REMOVED
            
            // Send basic "I'm alive" status without position data
            client.sendStatus("STMt")
            connectionManager.recordHeartbeatResponse()
            
            // Trigger immediate server time sync to GET position from server
            serverTimeSynchronizer.performImmediateSync()
            
            os_log(.info, log: logger, "📱 Sent foreground 'alive' status - letting server provide position")
        } else {
            // Connection lost in background - try to reconnect
            os_log(.error, log: logger, "📱 Connection lost in background - attempting reconnection")
            connect()
        }
        
        // Restart timer with normal interval
        if statusTimer != nil {
            startStatusTimer()
        }
        
        os_log(.info, log: logger, "📱 Server time sync adjusted for foreground")
    }
    
    func connectionManagerNetworkDidChange(isAvailable: Bool, isExpensive: Bool) {
        os_log(.info, log: logger, "🌐 Network change - Available: %{public}s, Expensive: %{public}s",
               isAvailable ? "YES" : "NO", isExpensive ? "YES" : "NO")
        
        if isAvailable {
            // Network became available - adjust strategy if needed
            if connectionManager.connectionState.canAttemptConnection {
                os_log(.info, log: logger, "🌐 Network available - attempting connection")
                connect()
            } else if connectionManager.connectionState.isConnected {
                // Network restored - trigger immediate server time sync
                serverTimeSynchronizer.performImmediateSync()
            }
        } else {
            // Network lost - server time sync will automatically handle this
            os_log(.error, log: logger, "🌐 Network lost - server time sync will fall back to local time")
        }
        
        // Restart status timer with appropriate interval for network type
        if statusTimer != nil {
            startStatusTimer()
        }
    }
    
    func connectionManagerShouldCheckHealth() {
        os_log(.info, log: logger, "💓 Connection health check requested")
        
        if connectionManager.connectionState.isConnected {
            // PHASE 2 FIX: Don't send position data during health checks
            // Remove these problematic lines:
            // let currentTime = audioManager.getCurrentTime()  // REMOVED
            // let isPlaying = audioManager.getPlayerState() == "Playing"  // REMOVED
            // client.setPlaybackState(isPlaying: isPlaying, position: currentTime)  // REMOVED
            
            // Send appropriate status based on stream state (not audio manager state)
            if commandHandler.streamState == "Paused" {
                client.sendStatus("STMp")  // Send pause status when paused
                os_log(.info, log: logger, "💓 Health check: sending pause status")
            } else {
                client.sendStatus("STMt")  // Send timer status when playing
                os_log(.info, log: logger, "💓 Health check: sending timer status")
            }
            
            // Also trigger server time sync as a health check
            serverTimeSynchronizer.performImmediateSync()
            
            os_log(.info, log: logger, "💓 Health check sent without position data")
        } else {
            os_log(.error, log: logger, "💓 Health check failed - not connected")
        }
    }
    
    func connectionManagerWillSleep() {
        os_log(.info, log: logger, "💤 Connection manager requesting sleep status")
        
        // Send sleep status to LMS to keep player in the list
        client.sendSleepStatus()
        
        // Give the message time to be sent before connection dies
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            os_log(.info, log: self.logger, "💤 Sleep status sent, connection will naturally close")
        }
    }
}

// MARK: - SlimProtoCommandHandlerDelegate
extension SlimProtoCoordinator: SlimProtoCommandHandlerDelegate {
    
    func didStartStream(url: String, format: String, startTime: Double) {
        os_log(.info, log: logger, "🎵 Starting audio stream: %{public}s (%{public}s)", url, format)
        
        // Use format-aware playback
        if startTime > 0 {
            os_log(.info, log: logger, "🔄 Picking up existing stream at position: %.2f seconds", startTime)
            audioManager.playStreamAtPositionWithFormat(urlString: url, startTime: startTime, format: format)
        } else {
            audioManager.playStreamWithFormat(urlString: url, format: format)
        }
        
        // PHASE 3 FIX: Don't report position back to server - it just told us the position!
        // Remove these problematic lines:
        // client.setPlaybackState(isPlaying: true, position: startTime)  // REMOVED
        // serverTimeSynchronizer.performImmediateSync()  // REMOVED - creates conflicts
        
        // Just acknowledge the stream start - no position data
        client.sendStatus("STMc")  // Connecting
        
        // Send started status after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.client.sendStatus("STMs")  // Started - let server track position from here
        }
        
        // Fetch metadata for lock screen (after longer delay to avoid conflicts)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.fetchCurrentTrackMetadata()
        }
        
        isStreamActive = true // Enable lock screen updates
         
         // Immediate lock screen update
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
             self.updateLockScreenTiming()
         }
        
        os_log(.info, log: logger, "✅ Stream start acknowledged - server maintains position authority")
    }
    
    func didPauseStream() {
        os_log(.info, log: logger, "⏸️ Server pause command")
        
        // Just pause the audio - don't report position back
        audioManager.pause()
        
        // PHASE 3 FIX: Don't report position back to server - it knows we're pausing
        // Remove these problematic lines:
        // let currentTime = audioManager.getCurrentTime()  // REMOVED
        // client.setPlaybackState(isPlaying: false, position: currentTime)  // REMOVED
        // serverTimeSynchronizer.performImmediateSync()  // REMOVED - creates conflicts
        
        // Just acknowledge the pause - no position data
        client.sendStatus("STMp")  // Paused acknowledgment
        
        os_log(.info, log: logger, "✅ Pause acknowledged - server maintains position authority")
        updateLockScreenTiming()
    }
    
    func didResumeStream() {
        os_log(.info, log: logger, "▶️ Server unpause command")
        
        // Just resume the audio - don't report position back
        audioManager.play()
        
        // PHASE 3 FIX: Don't report position back to server - it knows we're resuming
        // Remove these problematic lines:
        // let currentTime = audioManager.getCurrentTime()  // REMOVED
        // client.setPlaybackState(isPlaying: true, position: currentTime)  // REMOVED
        // serverTimeSynchronizer.performImmediateSync()  // REMOVED - creates conflicts
        
        // Just acknowledge the resume - no position data
        client.sendStatus("STMr")  // Resumed acknowledgment
        
        os_log(.info, log: logger, "✅ Resume acknowledged - server maintains position authority")
        updateLockScreenTiming()
    }
    
    func didStopStream() {
        os_log(.info, log: logger, "⏹️ Server stop command")
        
        // Just stop the audio
        audioManager.stop()
        
        // PHASE 3 FIX: Don't report position back to server
        // Remove these problematic lines:
        // client.setPlaybackState(isPlaying: false, position: 0.0)  // REMOVED
        
        // Just acknowledge the stop
        client.sendStatus("STMf")  // Stopped/Flushed acknowledgment
        
        os_log(.info, log: logger, "✅ Stop acknowledged")
        isStreamActive = false // Disable lock screen updates
        updateLockScreenTiming() // Final update
    }
    
    func didReceiveStatusRequest() {
        // Get timing information for comparison but don't immediately send it back
        let serverTime = serverTimeSynchronizer.getCurrentInterpolatedTime()
        let audioTime = audioManager.getCurrentTime()
        
        // Log the time sources for debugging
        os_log(.debug, log: logger, "📊 Status requested - server: %.2f, audio: %.2f",
               serverTime.time, audioTime)
        
        // PHASE 3 FIX: Don't send position data back to server during status requests
        // Remove these problematic lines:
        // let actualTime: Double = ...  // REMOVED
        // client.setPlaybackState(isPlaying: isPlaying, position: actualTime)  // REMOVED
        
        // Only update command handler's internal tracking (not sent to server)
        if serverTime.isServerTime {
            commandHandler.updatePlaybackPosition(serverTime.time)
            
            // If there's a large discrepancy, log it but don't auto-correct
            let timeDifference = abs(serverTime.time - audioTime)
            if timeDifference > 5.0 && audioTime > 0.1 {
                os_log(.info, log: logger, "ℹ️ Time difference noted: audio=%.2f, server=%.2f (diff=%.2f)",
                       audioTime, serverTime.time, timeDifference)
                // Note: We don't auto-seek anymore - let server control this
            }
        } else {
            commandHandler.updatePlaybackPosition(audioTime)
        }
        
        // Record that we handled a status request (shows connection is alive)
        connectionManager.recordHeartbeatResponse()
        
        // PHASE 3 FIX: Don't trigger immediate server sync during status requests
        // Remove this line:
        // serverTimeSynchronizer.performImmediateSync()  // REMOVED - creates timing loops
        
        os_log(.debug, log: logger, "📊 Status request handled - no position sent back to server")
        updateLockScreenTiming()
    }
}

// MARK: - Lock Screen Integration
extension SlimProtoCoordinator {
    
    func sendLockScreenCommand(_ command: String) {
        os_log(.info, log: logger, "🔒 Lock Screen command: %{public}s", command)
        
        guard connectionManager.connectionState.isConnected else {
            os_log(.error, log: logger, "Cannot send lock screen command - not connected to server")
            return
        }
        
        switch command.lowercased() {
        case "play":
            sendJSONRPCCommand("play")
            os_log(.info, log: logger, "✅ Sent resume command to LMS server")
            
        case "pause":
            let currentTime = audioManager.getCurrentTime()
            sendJSONRPCCommand("pause")
            os_log(.info, log: logger, "✅ Sent pause command to LMS server (position: %.2f)", currentTime)
            
        case "stop":
            sendJSONRPCCommand("stop")
            os_log(.info, log: logger, "✅ Sent stop command to LMS server")
            
        case "next":
            sendJSONRPCCommand("playlist", parameters: ["index", "+1"])
            os_log(.info, log: logger, "✅ Sent next track command to LMS server")
            
        case "previous":
            sendJSONRPCCommand("playlist", parameters: ["index", "-1"])
            os_log(.info, log: logger, "✅ Sent previous track command to LMS server")
            
        default:
            os_log(.error, log: logger, "Unknown lock screen command: %{public}s", command)
        }
        
        // Trigger immediate server time sync after any command
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.serverTimeSynchronizer.performImmediateSync()
            self.updateLockScreenTiming()
        }
    }
    
    private func sendJSONRPCCommand(_ command: String, parameters: [String] = []) {
        let playerID = settings.playerMACAddress
        
        var jsonRPCCommand: [String: Any]
        
        switch command.lowercased() {
        case "pause":
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["pause", "1"]]
            ]
        case "play":
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["pause", "0"]]
            ]
        case "stop":
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["stop"]]
            ]
        case "playlist":
            var commandParams = [command]
            commandParams.append(contentsOf: parameters)
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, commandParams]
            ]
        default:
            os_log(.error, log: logger, "Unknown JSON-RPC command: %{public}s", command)
            return
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPCCommand) else {
            os_log(.error, log: logger, "Failed to create JSON-RPC command for %{public}s", command)
            return
        }
        
        // Send API request to LMS
        let webPort = settings.serverWebPort
        let host = settings.serverHost
        var request = URLRequest(url: URL(string: "http://\(host):\(webPort)/jsonrpc.js")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self.logger, "JSON-RPC %{public}s command failed: %{public}s", command, error.localizedDescription)
                } else {
                    os_log(.info, log: self.logger, "✅ JSON-RPC %{public}s command sent successfully", command)
                    
                    // For skip commands, refresh metadata after a delay
                    if command == "playlist" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.fetchCurrentTrackMetadata()
                        }
                    }
                }
            }
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Sent JSON-RPC %{public}s command to LMS", command)
    }
}

// MARK: - Metadata Integration
extension SlimProtoCoordinator {
    
    private func fetchCurrentTrackMetadata() {
        let playerID = settings.playerMACAddress
        
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                [
                    "status", "-", "1",
                    "tags:u,a,A,l,t,d,e,s,o,r,c,g,p,i,q,y,j,J,K,N,S,w,x,C,G,R,T,I,D,U,F,L,f,n,m,b,v,h,k,z"
                ]
            ]
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create metadata request")
            return
        }
        
        let webPort = settings.serverWebPort
        let host = settings.serverHost
        var request = URLRequest(url: URL(string: "http://\(host):\(webPort)/jsonrpc.js")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: self.logger, "Metadata request failed: %{public}s", error.localizedDescription)
                return
            }
            
            guard let data = data else {
                os_log(.error, log: self.logger, "No metadata received")
                return
            }
            
            self.parseTrackMetadata(data: data)
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Requesting track metadata")
    }
    
    private func parseTrackMetadata(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let loop = result["playlist_loop"] as? [[String: Any]],
               let firstTrack = loop.first {
                
                let trackTitle = firstTrack["title"] as? String ??
                               firstTrack["track"] as? String ?? "LMS Stream"
                
                let trackAlbum = firstTrack["album"] as? String ?? "Lyrion Music Server"
                let duration = firstTrack["duration"] as? Double ?? 0.0
                
                // Enhanced artist extraction
                var trackArtist = "Unknown Artist"
                
                if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                    trackArtist = artist
                } else if let albumArtist = firstTrack["albumartist"] as? String, !albumArtist.isEmpty {
                    trackArtist = albumArtist
                } else if let contributors = firstTrack["contributors"] as? [[String: Any]] {
                    for contributor in contributors {
                        if let role = contributor["role"] as? String,
                           let name = contributor["name"] as? String,
                           role.lowercased().contains("artist") {
                            trackArtist = name
                            break
                        }
                    }
                }
                
                // Create artwork URL
                var artworkURL: String? = nil
                if let trackID = firstTrack["id"] as? Int {
                    let webPort = settings.serverWebPort
                    let host = settings.serverHost
                    artworkURL = "http://\(host):\(webPort)/music/\(trackID)/cover.jpg"
                }
                
                os_log(.info, log: logger, "🎵 Metadata: '%{public}s' by %{public}s", trackTitle, trackArtist)
                
                DispatchQueue.main.async {
                    self.audioManager.updateTrackMetadata(
                        title: trackTitle,
                        artist: trackArtist,
                        album: trackAlbum,
                        artworkURL: artworkURL,
                        duration: duration
                    )
                }
                
            } else {
                os_log(.error, log: logger, "Failed to parse metadata response")
            }
        } catch {
            os_log(.error, log: logger, "JSON parsing error: %{public}s", error.localizedDescription)
        }
    }
}

// MARK: - Background Strategy Extension
extension SlimProtoConnectionManager.BackgroundStrategy {
    var description: String {
        switch self {
        case .normal: return "normal"
        case .reduced: return "reduced"
        case .minimal: return "minimal"
        case .suspended: return "suspended"
        }
    }
}
