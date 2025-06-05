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
        
        os_log(.info, log: logger, "Status timer started with %.1f second interval (%{public}s strategy)",
               interval, connectionManager.backgroundConnectionStrategy.description)
    }
    
    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
    
    private func sendPeriodicStatus() {
        // Don't send if we just sent one recently (avoid spam)
        if let lastSent = lastStatusSent, Date().timeIntervalSince(lastSent) < 5.0 {
            return
        }
        
        // Update position from audio manager before sending status
        let currentTime = audioManager.getCurrentTime()
        commandHandler.updatePlaybackPosition(currentTime)
        
        // Update client with current position and state
        let isPlaying = audioManager.getPlayerState() == "Playing"
        client.setPlaybackState(isPlaying: isPlaying, position: currentTime)
        
        // Only send heartbeat if we have an active stream
        if commandHandler.streamState != "Stopped" {
            client.sendStatus("STMt")
            lastStatusSent = Date()
            
            // Record heartbeat for health monitoring
            connectionManager.recordHeartbeatResponse()
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
            let currentTime = audioManager.getCurrentTime()
            let isCurrentlyPlaying = audioManager.getPlayerState() == "Playing"
            
            // Update client state
            client.setPlaybackState(isPlaying: isCurrentlyPlaying, position: currentTime)
            
            // Send status to server immediately
            client.sendStatus("STMt")
            connectionManager.recordHeartbeatResponse()
            
            os_log(.info, log: logger, "📱 Sent background status - Playing: %{public}s, Position: %.2f, Time remaining: %.0f sec",
                   isCurrentlyPlaying ? "YES" : "NO", currentTime, connectionManager.backgroundTimeRemaining)
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
            let currentTime = audioManager.getCurrentTime()
            let isCurrentlyPlaying = audioManager.getPlayerState() == "Playing"
            
            // Update client state
            client.setPlaybackState(isPlaying: isCurrentlyPlaying, position: currentTime)
            
            // Send immediate status update
            client.sendStatus("STMt")
            connectionManager.recordHeartbeatResponse()
            
            // Trigger immediate server time sync
            serverTimeSynchronizer.performImmediateSync()
            
            os_log(.info, log: logger, "📱 Sent foreground status - Playing: %{public}s, Position: %.2f",
                   isCurrentlyPlaying ? "YES" : "NO", currentTime)
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
        
        // Send a test status to verify connection is alive
        if connectionManager.connectionState.isConnected {
            let currentTime = audioManager.getCurrentTime()
            let isPlaying = audioManager.getPlayerState() == "Playing"
            
            // Update client state
            client.setPlaybackState(isPlaying: isPlaying, position: currentTime)
            
            // Send status - if this fails, we'll get a disconnect event
            client.sendStatus("STMt")
            
            // Also trigger server time sync as a health check
            serverTimeSynchronizer.performImmediateSync()
            
            os_log(.info, log: logger, "💓 Health check status and server time sync sent")
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
        
        // Update the client with stream start
        client.setPlaybackState(isPlaying: true, position: startTime)
        
        // Trigger immediate server time sync for new stream
        serverTimeSynchronizer.performImmediateSync()
        
        // Fetch metadata for lock screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.fetchCurrentTrackMetadata()
        }
    }
    
    func didPauseStream() {
        os_log(.info, log: logger, "⏸️ Pausing audio")
        let currentTime = audioManager.getCurrentTime()
        audioManager.pause()
        
        // Update client with actual current position
        client.setPlaybackState(isPlaying: false, position: currentTime)
        
        // Trigger server time sync to get accurate pause position
        serverTimeSynchronizer.performImmediateSync()
    }
    
    func didResumeStream() {
        os_log(.info, log: logger, "▶️ Resuming audio")
        let currentTime = audioManager.getCurrentTime()
        audioManager.play()
        
        // Update client with actual current position
        client.setPlaybackState(isPlaying: true, position: currentTime)
        
        // Trigger server time sync for resume
        serverTimeSynchronizer.performImmediateSync()
    }
    
    func didStopStream() {
        os_log(.info, log: logger, "⏹️ Stopping audio")
        audioManager.stop()
        
        // Update client with stop state
        client.setPlaybackState(isPlaying: false, position: 0.0)
        
        // Server time sync will automatically handle stopped state
    }
    
    func didReceiveStatusRequest() {
        // Handle status requests - get ACTUAL time from audio manager
        let currentTime = audioManager.getCurrentTime()
        os_log(.debug, log: logger, "📊 Status requested - current time: %.2f", currentTime)
        
        // Update command handler with real position
        commandHandler.updatePlaybackPosition(currentTime)
        
        // Update client with real position and state
        let isPlaying = audioManager.getPlayerState() == "Playing"
        client.setPlaybackState(isPlaying: isPlaying, position: currentTime)
        
        // Record that we handled a status request (shows connection is alive)
        connectionManager.recordHeartbeatResponse()
        
        // Trigger server time sync to stay synchronized
        serverTimeSynchronizer.performImmediateSync()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.serverTimeSynchronizer.performImmediateSync()
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
