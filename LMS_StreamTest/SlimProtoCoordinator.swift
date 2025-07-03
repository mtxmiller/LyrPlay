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
    
    private var metadataRefreshTimer: Timer?
    
    // MARK: - Settings Tracking (ADD THESE LINES)
    private(set) var lastKnownHost: String = ""
    private(set) var lastKnownPort: UInt16 = 3483
    private var playbackHeartbeatTimer: Timer?

    
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
        setupAudioPlayerIntegration()

        os_log(.info, log: logger, "SlimProtoCoordinator initialized with ServerTimeSynchronizer")
    }
    
    // MARK: - Setup
    private func setupDelegation() {
        // Connect client to coordinator
        client.delegate = self
        
        // Connect command handler to client and coordinator
        commandHandler.slimProtoClient = client
        commandHandler.delegate = self
        
        // ADD THIS LINE - Connect ServerTimeSynchronizer to command handler
        commandHandler.serverTimeSynchronizer = serverTimeSynchronizer
        
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
    
    func setupAudioManagerIntegration() {
        audioManager.setCommandHandler(commandHandler)
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
        os_log(.info, log: logger, "Starting connection to %{public}s server...", settings.currentActiveServer.displayName)
        
        lastKnownHost = settings.activeServerHost
        lastKnownPort = UInt16(settings.activeServerSlimProtoPort)
        
        connectionManager.willConnect()
        client.updateServerSettings(host: settings.activeServerHost, port: UInt16(settings.activeServerSlimProtoPort))
        client.connect()
    }
    
    func disconnect() {
        os_log(.info, log: logger, "User requested disconnection")
        connectionManager.userInitiatedDisconnection()
        stopServerTimeSync()
        client.disconnect()
    }
    
    func updateServerSettings(host: String, port: UInt16) {
        // Store current settings for change detection
        lastKnownHost = host
        lastKnownPort = port
        
        // Update the client
        client.updateServerSettings(host: host, port: port)
        
        os_log(.info, log: logger, "Server settings updated and tracked - Host: %{public}s, Port: %d", host, port)
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
    
    func requestFreshMetadata() {
        os_log(.info, log: logger, "🔄 Requesting fresh metadata due to stream change")
        fetchCurrentTrackMetadata()
    }
    
    private func startPlaybackHeartbeat() {
        stopPlaybackHeartbeat()
        
        // Only during active playback, send STMt every second like squeezelite
        playbackHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Only send if actively playing (not paused/stopped)
            if self.audioManager.getPlayerState() == "playing" && !self.commandHandler.isPausedByLockScreen {
                self.client.sendStatus("STMt")
            }
        }
    }

    private func stopPlaybackHeartbeat() {
        playbackHeartbeatTimer?.invalidate()
        playbackHeartbeatTimer = nil
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
    
    private func startMetadataRefreshForRadio() {
        // Stop any existing timer
        stopMetadataRefresh()
        
        // For radio streams, refresh metadata every 30 seconds to catch track changes
        metadataRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.fetchCurrentTrackMetadata()
        }
        
        os_log(.info, log: logger, "🎵 Started automatic metadata refresh for radio stream")
    }

    private func stopMetadataRefresh() {
        metadataRefreshTimer?.invalidate()
        metadataRefreshTimer = nil
    }
    
    private func setupAudioPlayerIntegration() {
        audioManager.setCommandHandler(commandHandler)
    }
    
    deinit {
        stopServerTimeSync()
        stopMetadataRefresh()  // Add this line
        disconnect()
    }
    
    
}

// MARK: - SlimProtoClientDelegate
extension SlimProtoCoordinator: SlimProtoClientDelegate {
    
    func slimProtoDidConnect() {
        os_log(.info, log: logger, "✅ Connection established")
        connectionManager.didConnect()
        
        // Don't start any status timers here
        // Heartbeat only starts during playback
        
        startServerTimeSync()
        setupNowPlayingManagerIntegration()
    }

    func slimProtoDidDisconnect(error: Error?) {
        os_log(.info, log: logger, "🔌 Connection lost")
        connectionManager.didDisconnect(error: error)
        
        stopPlaybackHeartbeat()  // ← Correct timer
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
        
        // Try backup server if primary fails and backup is available
        if settings.currentActiveServer == .primary &&
           settings.isBackupServerEnabled &&
           !settings.backupServerHost.isEmpty {
            
            os_log(.info, log: logger, "🔄 Primary server failed - trying backup server")
            settings.switchToBackupServer()
            
            // Update client with backup server settings
            client.updateServerSettings(
                host: settings.activeServerHost,
                port: UInt16(settings.activeServerSlimProtoPort)
            )
        }
        
        client.connect()
    }
    
    func connectionManagerDidEnterBackground() {
        // Connection will naturally pause/close
        // Server handles this gracefully
    }
    
    func connectionManagerDidEnterForeground() {
        if connectionManager.connectionState.isConnected {
            serverTimeSynchronizer.performImmediateSync()
        } else {
            connect()
        }
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
        
    }
    
    func connectionManagerShouldCheckHealth() {
        // Server polls us with strm 't' commands
        // No need to send unsolicited status
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
        os_log(.info, log: logger, "🎵 Starting stream: %{public}s from %.2f", format, startTime)
        
        // Stop any existing playback and timers first
        audioManager.stop()
        stopPlaybackHeartbeat()
        
        // Start the new stream
        if startTime > 0 {
            audioManager.playStreamAtPositionWithFormat(urlString: url, startTime: startTime, format: format)
        } else {
            audioManager.playStreamWithFormat(urlString: url, format: format)
        }
        
        // IMPORTANT: Tell server time synchronizer we're starting to play
        // Fixed: should be 'true' since we're starting playback
        serverTimeSynchronizer.updatePlaybackState(isPlaying: true)
        
        // Start the 1-second heartbeat timer (like squeezelite)
        // This replaces all the delayed status messages
        startPlaybackHeartbeat()
        
        // After starting the stream, wait a moment then send STMs
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.client.sendStatus("STMs")  // Track started
        }
        
        // Get metadata and sync with server
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.fetchCurrentTrackMetadata()
            
            // Check if this is a radio stream and start automatic refresh
            if url.contains("stream") || url.contains("radio") || url.contains("live") {
                self.startMetadataRefreshForRadio()
            }
        }
        
        // Trigger server time sync after connection stabilizes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.serverTimeSynchronizer.performImmediateSync()
        }
    }
    
    func didPauseStream() {
        os_log(.info, log: logger, "⏸️ Server pause command")
        
        audioManager.pause()
        serverTimeSynchronizer.updatePlaybackState(isPlaying: false)
        
        // Stop heartbeat when paused
        stopPlaybackHeartbeat()
        
        client.sendStatus("STMp")
    }

    func didResumeStream() {
        os_log(.info, log: logger, "▶️ Server unpause command")
        
        audioManager.play()
        serverTimeSynchronizer.updatePlaybackState(isPlaying: true)
        
        // Restart heartbeat when resumed
        startPlaybackHeartbeat()
        
        client.sendStatus("STMr")
    }

    func didStopStream() {
        os_log(.info, log: logger, "⏹️ Server stop command")
        
        audioManager.stop()
        serverTimeSynchronizer.updatePlaybackState(isPlaying: false)
        
        // Stop heartbeat when stopped
        stopPlaybackHeartbeat()
        
        client.sendStatus("STMf")
    }
    
    func getCurrentAudioTime() -> Double {
        return audioManager.getCurrentTime()
    }

    func didReceiveStatusRequest() {
        // Server is asking "are you alive?" - just confirm we're here
        // Don't confuse it with local player timing information
        
        let statusCode: String
        if commandHandler.streamState == "Paused" {
            statusCode = "STMp"  // We're paused
        } else {
            statusCode = "STMt"  // We're playing/ready
        }
        
        client.sendStatus(statusCode)
        
        // Record that we responded (shows connection is alive)
        connectionManager.recordHeartbeatResponse()
        
        //os_log(.debug, log: logger, "📍 Responded to server status request with %{public}s", statusCode)
    }
    
    
}

// MARK: - Enhanced Lock Screen Integration with SlimProto Connection Fix
extension SlimProtoCoordinator {
    
    func sendLockScreenCommand(_ command: String) {
        os_log(.info, log: logger, "🔒 Lock Screen command: %{public}s", command)
        
        // CRITICAL FIX: Always ensure SlimProto connection for audio streaming
        if !connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "❌ No SlimProto connection - starting full reconnection sequence")
            handleDisconnectedLockScreenCommand(command)
            return
        }
        
        // If connected, send command via JSON-RPC (faster) but ensure SlimProto stays connected
        sendJSONRPCCommand(command)
    }
    
    private func handleDisconnectedLockScreenCommand(_ command: String) {
        os_log(.info, log: logger, "🔄 Starting FULL reconnection sequence for: %{public}s", command)
        
        // Step 1: Force stop any existing broken connections
        disconnect()
        
        // Step 2: Wait a moment for cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Step 3: Start fresh connection
            self.connectionManager.resetReconnectionAttempts()
            self.connect()
            
            // Step 4: Monitor connection and send command
            self.waitForConnectionAndExecute(command: command)
        }
    }
    
    private func waitForConnectionAndExecute(command: String, attempt: Int = 0) {
        let maxAttempts = 20 // 20 seconds total wait
        
        if connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "✅ SlimProto reconnected after %d seconds", attempt)
            
            // Send the command via JSON-RPC (faster response)
            sendJSONRPCCommand(command)
            
            // CRITICAL: Also send a SlimProto status to ensure the connection works
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.client.sendStatus("STMt")
                os_log(.info, log: self.logger, "📡 Sent SlimProto heartbeat to verify connection")
            }
            
        } else if attempt < maxAttempts {
            // Keep waiting
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.waitForConnectionAndExecute(command: command, attempt: attempt + 1)
            }
        } else {
            // Timeout - try JSON-RPC only as fallback
            os_log(.error, log: logger, "⏰ SlimProto connection timeout - using JSON-RPC fallback")
            sendJSONRPCCommand(command)
        }
    }
    
    private func sendJSONRPCCommand(_ command: String, retryCount: Int = 0) {
        // CRITICAL FIX: For pause commands, get current server position FIRST
        if command.lowercased() == "pause" {
            os_log(.info, log: logger, "🔒 Pause command - getting current server position first")
            serverTimeSynchronizer.forceImmediateSync()
            
            // Wait a moment for sync to complete, then continue with normal pause logic
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Now do the normal pause command processing
                self.sendNormalJSONRPCCommand("pause", retryCount: retryCount)
            }
            return
        }
        
        // For non-pause commands, process normally
        sendNormalJSONRPCCommand(command, retryCount: retryCount)
    }

    // ADD this new method right after the sendJSONRPCCommand method:
    private func sendNormalJSONRPCCommand(_ command: String, retryCount: Int = 0) {
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
        case "next":
            // CRITICAL: Prevent track end detection during manual skip
            commandHandler.startSkipProtection()
            
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlist", "index", "+1"]]
            ]
        case "previous":
            // CRITICAL: Prevent track end detection during manual skip
            commandHandler.startSkipProtection()
            
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlist", "index", "-1"]]
            ]
        default:
            os_log(.error, log: logger, "Unknown JSON-RPC command: %{public}s", command)
            return
        }
        
        sendJSONCommand(jsonRPCCommand, command: command, retryCount: retryCount)
    }
    
    private func sendJSONCommand(_ jsonRPC: [String: Any], command: String, retryCount: Int = 0) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create JSON-RPC command for %{public}s", command)
            return
        }
        
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        guard let url = URL(string: "http://\(host):\(webPort)/jsonrpc.js") else {
            os_log(.error, log: logger, "Invalid server URL for JSON-RPC")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 10.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self.logger, "JSON-RPC %{public}s failed: %{public}s", command, error.localizedDescription)
                    
                    if retryCount < 2 && (command.lowercased() == "play" || command.lowercased() == "pause") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.sendJSONRPCCommand(command, retryCount: retryCount + 1)
                        }
                    }
                } else {
                    os_log(.info, log: self.logger, "✅ JSON-RPC %{public}s command sent successfully", command)
                    
                    // CRITICAL: For play commands, ensure we have a working SlimProto connection
                    if command.lowercased() == "play" {
                        self.ensureSlimProtoConnection()
                    }
                    
                    // For skip commands, refresh metadata
                    if command == "next" || command == "previous" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.fetchCurrentTrackMetadata()
                        }
                    }
                }
            }
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Sent JSON-RPC %{public}s command to LMS", command)
    }
    
    // CRITICAL: Ensure SlimProto connection for audio streaming
    private func ensureSlimProtoConnection() {
        os_log(.info, log: logger, "🔧 Ensuring SlimProto connection for audio streaming...")
        
        if !connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "🔄 SlimProto not connected - reconnecting for audio stream")
            connect()
            
            // Monitor connection establishment
            var waitTime = 0
            let connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                waitTime += 1
                
                if self.connectionManager.connectionState.isConnected {
                    os_log(.info, log: self.logger, "✅ SlimProto connection established for audio stream")
                    timer.invalidate()
                    
                    // Send status to activate audio streaming
                    self.client.sendStatus("STMt")
                    
                    // Start server time sync for position tracking
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.serverTimeSynchronizer.performImmediateSync()
                    }
                    
                } else if waitTime >= 15 {
                    os_log(.error, log: self.logger, "❌ SlimProto connection failed - audio may not work")
                    timer.invalidate()
                }
            }
        } else {
            os_log(.info, log: logger, "✅ SlimProto already connected")
            
            // Send heartbeat to ensure connection is working
            client.sendStatus("STMt")
            
            // Trigger server time sync
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.serverTimeSynchronizer.performImmediateSync()
            }
        }
    }
}


// MARK: - Metadata Integration
extension SlimProtoCoordinator {
    
    private func fetchCurrentTrackMetadata() {
        let playerID = settings.playerMACAddress
        
        // ENHANCED: Request additional tags for radio/plugin artwork support
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                [
                    "status", "-", "1",
                    // ENHANCED: Added artwork_url (u), coverid (c), icon (i), and image tags
                    "tags:u,a,A,l,t,d,e,s,o,r,c,g,p,i,q,y,j,J,K,N,S,w,x,C,G,R,T,I,D,U,F,L,f,n,m,b,v,h,k,z,url,remote_title,bitrate"
                ]
            ]
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create enhanced metadata request")
            return
        }
        
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        var request = URLRequest(url: URL(string: "http://\(host):\(webPort)/jsonrpc.js")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: self.logger, "Enhanced metadata request failed: %{public}s", error.localizedDescription)
                return
            }
            
            guard let data = data else {
                os_log(.error, log: self.logger, "No enhanced metadata received")
                return
            }
            
            self.parseTrackMetadata(data: data)
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Requesting enhanced track metadata with radio stream support")
    }
    
    // Replace the parseTrackMetadata method in SlimProtoCoordinator.swift
    private func parseTrackMetadata(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let loop = result["playlist_loop"] as? [[String: Any]],
               let firstTrack = loop.first {
                
                // DEBUG: Log all available fields to understand what's available
                os_log(.info, log: logger, "🔍 Available metadata fields: %{public}s", firstTrack.keys.sorted().joined(separator: ", "))
                
                // Log some key fields for debugging
                if let remoteTitle = firstTrack["remote_title"] as? String {
                    os_log(.info, log: logger, "🔍 remote_title: %{public}s", remoteTitle)
                }
                if let title = firstTrack["title"] as? String {
                    os_log(.info, log: logger, "🔍 title: %{public}s", title)
                }
                if let artist = firstTrack["artist"] as? String {
                    os_log(.info, log: logger, "🔍 artist: %{public}s", artist)
                }
                if let track = firstTrack["track"] as? String {
                    os_log(.info, log: logger, "🔍 track: %{public}s", track)
                }
                
                // ENHANCED: Handle radio stream metadata with better field priority
                var trackTitle = "LMS Stream"
                var trackArtist = "Unknown Artist"
                var isRadioStream = false
                
                // Check if this is a radio stream by looking for indicators
                if let url = firstTrack["url"] as? String {
                    isRadioStream = url.contains("stream") || url.contains("radio") || url.contains("live") ||
                                   url.contains(".pls") || url.contains(".m3u") || url.hasPrefix("http")
                }
                
                if isRadioStream {
                    os_log(.info, log: logger, "🎵 Detected radio stream - using radio-specific parsing")
                    
                    // For radio streams, prioritize fields that contain current song info
                    // Priority 1: Check 'title' field first (often contains current song)
                    if let title = firstTrack["title"] as? String, !title.isEmpty &&
                       !title.contains("(pls)") && !title.contains("FM") && !title.contains("Radio") {
                        
                        // Parse "Artist - Title" format if present
                        let components = title.components(separatedBy: " - ")
                        if components.count >= 2 {
                            trackArtist = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            trackTitle = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                            os_log(.info, log: logger, "🎵 Parsed from title field: '%{public}s' by %{public}s", trackTitle, trackArtist)
                        } else {
                            trackTitle = title
                            // FIXED: Also check for separate artist field when title doesn't contain " - "
                            if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                                trackArtist = artist
                                os_log(.info, log: logger, "🎵 Using title + separate artist: '%{public}s' by %{public}s", trackTitle, trackArtist)
                            } else {
                                os_log(.info, log: logger, "🎵 Using title field only: %{public}s", trackTitle)
                            }
                        }
                    }
                    // Priority 2: Check 'track' field (sometimes contains current song)
                    else if let track = firstTrack["track"] as? String, !track.isEmpty &&
                            !track.contains("(pls)") && !track.contains("FM") && !track.contains("Radio") {
                        
                        let components = track.components(separatedBy: " - ")
                        if components.count >= 2 {
                            trackArtist = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            trackTitle = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                            os_log(.info, log: logger, "🎵 Parsed from track field: '%{public}s' by %{public}s", trackTitle, trackArtist)
                        } else {
                            trackTitle = track
                            // FIXED: Also check for separate artist field
                            if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                                trackArtist = artist
                                os_log(.info, log: logger, "🎵 Using track + separate artist: '%{public}s' by %{public}s", trackTitle, trackArtist)
                            } else {
                                os_log(.info, log: logger, "🎵 Using track field only: %{public}s", trackTitle)
                            }
                        }
                    }
                    // Priority 3: Try remote_title but filter out station names
                    else if let remoteTitle = firstTrack["remote_title"] as? String, !remoteTitle.isEmpty &&
                            !remoteTitle.contains("(pls)") && !remoteTitle.contains("FM") && !remoteTitle.contains("Radio") {
                        
                        let components = remoteTitle.components(separatedBy: " - ")
                        if components.count >= 2 {
                            trackArtist = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            trackTitle = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                            os_log(.info, log: logger, "🎵 Parsed from remote_title: '%{public}s' by %{public}s", trackTitle, trackArtist)
                        } else {
                            trackTitle = remoteTitle
                            // FIXED: Also check for separate artist field
                            if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                                trackArtist = artist
                                os_log(.info, log: logger, "🎵 Using remote_title + separate artist: '%{public}s' by %{public}s", trackTitle, trackArtist)
                            } else {
                                os_log(.info, log: logger, "🎵 Using remote_title only: %{public}s", trackTitle)
                            }
                        }
                    }
                    // Priority 4: Use separate title and artist fields
                    else {
                        if let title = firstTrack["title"] as? String, !title.isEmpty {
                            trackTitle = title
                        } else if let track = firstTrack["track"] as? String, !track.isEmpty {
                            trackTitle = track
                        }
                        
                        if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                            trackArtist = artist
                        }
                        
                        os_log(.info, log: logger, "🎵 Using fallback separate fields: '%{public}s' by %{public}s", trackTitle, trackArtist)
                    }
                    
                    // REMOVED: The section that looks for station names and overwrites good data
                    // We already have the correct title and artist, don't second-guess it
                } else {
                    // Non-radio stream - use original logic
                    trackTitle = firstTrack["title"] as? String ??
                               firstTrack["track"] as? String ?? "LMS Stream"
                    
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
                    os_log(.info, log: logger, "🎵 Non-radio metadata: '%{public}s' by %{public}s", trackTitle, trackArtist)
                }
                
                let trackAlbum = firstTrack["album"] as? String ?? (isRadioStream ? firstTrack["remote_title"] as? String ?? "Internet Radio" : "Lyrion Music Server")
                let duration = firstTrack["duration"] as? Double ?? 0.0
                
                // ENHANCED: Multi-source artwork URL detection (existing code remains the same)
                var artworkURL: String? = nil
                
                // Priority 1: Check for remote artwork URL (radio stations, plugins like Radio Paradise, TuneIn, etc.)
                if let remoteArtworkURL = firstTrack["artwork_url"] as? String, !remoteArtworkURL.isEmpty {
                    // Handle both relative and absolute URLs
                    if remoteArtworkURL.hasPrefix("http://") || remoteArtworkURL.hasPrefix("https://") {
                        // Absolute URL - use as-is (common for Radio Paradise, TuneIn, etc.)
                        artworkURL = remoteArtworkURL
                        os_log(.info, log: logger, "🖼️ Using remote artwork URL: %{public}s", remoteArtworkURL)
                    } else if remoteArtworkURL.hasPrefix("/") {
                        // Relative URL - prepend server address
                        let webPort = settings.activeServerWebPort
                        let host = settings.activeServerHost
                        artworkURL = "http://\(host):\(webPort)\(remoteArtworkURL)"
                        os_log(.info, log: logger, "🖼️ Using server-relative artwork URL: %{public}s", artworkURL!)
                    }
                }
                
                // Priority 2: Check for coverid (local music library)
                if artworkURL == nil, let coverid = firstTrack["coverid"] as? String, !coverid.isEmpty, coverid != "0" {
                    let webPort = settings.activeServerWebPort
                    let host = settings.activeServerHost
                    artworkURL = "http://\(host):\(webPort)/music/\(coverid)/cover.jpg"
                    os_log(.info, log: logger, "🖼️ Using coverid artwork: %{public}s", artworkURL!)
                }
                
                // Priority 3: Fallback to track ID (legacy method for local tracks)
                if artworkURL == nil, let trackID = firstTrack["id"] as? Int {
                    let webPort = settings.activeServerWebPort
                    let host = settings.activeServerHost
                    artworkURL = "http://\(host):\(webPort)/music/\(trackID)/cover.jpg"
                    os_log(.info, log: logger, "🖼️ Using fallback track ID artwork: %{public}s", artworkURL!)
                }
                
                // Priority 4: Check for plugin-specific icon/image fields
                if artworkURL == nil {
                    // Some plugins use 'icon' field
                    if let iconURL = firstTrack["icon"] as? String, !iconURL.isEmpty {
                        if iconURL.hasPrefix("http://") || iconURL.hasPrefix("https://") {
                            artworkURL = iconURL
                            os_log(.info, log: logger, "🖼️ Using plugin icon URL: %{public}s", iconURL)
                        } else if iconURL.hasPrefix("/") {
                            let webPort = settings.activeServerWebPort
                            let host = settings.activeServerHost
                            artworkURL = "http://\(host):\(webPort)\(iconURL)"
                            os_log(.info, log: logger, "🖼️ Using server-relative icon URL: %{public}s", artworkURL!)
                        }
                    }
                    // Some plugins use 'image' field
                    else if let imageURL = firstTrack["image"] as? String, !imageURL.isEmpty {
                        if imageURL.hasPrefix("http://") || imageURL.hasPrefix("https://") {
                            artworkURL = imageURL
                            os_log(.info, log: logger, "🖼️ Using plugin image URL: %{public}s", imageURL)
                        } else if imageURL.hasPrefix("/") {
                            let webPort = settings.activeServerWebPort
                            let host = settings.activeServerHost
                            artworkURL = "http://\(host):\(webPort)\(imageURL)"
                            os_log(.info, log: logger, "🖼️ Using server-relative image URL: %{public}s", artworkURL!)
                        }
                    }
                }
                
                // Enhanced logging based on source type
                let sourceType = determineSourceType(from: firstTrack)
                os_log(.info, log: logger, "🎵 Final Metadata (%{public}s): '%{public}s' by %{public}s%{public}s",
                       sourceType, trackTitle, trackArtist, artworkURL != nil ? " [with artwork]" : "")
                
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
    
    // MARK: - Helper Method to Determine Source Type
    private func determineSourceType(from trackData: [String: Any]) -> String {
        // Check various indicators to determine the source type
        
        // Check for Radio Paradise specific fields
        if let url = trackData["url"] as? String {
            if url.contains("radioparadise.com") {
                return "Radio Paradise"
            }
            if url.contains("tunein.com") || url.contains("radiotime.com") {
                return "TuneIn Radio"
            }
            if url.contains("somafm.com") {
                return "SomaFM"
            }
            if url.contains("spotify.com") {
                return "Spotify"
            }
            if url.contains("tidal.com") {
                return "Tidal"
            }
            if url.contains("qobuz.com") {
                return "Qobuz"
            }
            // Generic radio stream detection
            if url.contains(".pls") || url.contains(".m3u") || url.contains("stream") {
                return "Internet Radio"
            }
        }
        
        // Check for remote_title which often indicates streaming
        if trackData["remote_title"] != nil {
            return "Internet Radio"
        }
        
        // Check for plugin-specific fields
        if trackData["icon"] != nil || trackData["image"] != nil {
            return "Plugin Stream"
        }
        
        // Check if it has a file path (local music)
        if let trackID = trackData["id"] as? Int, trackID > 0 {
            return "Local Music"
        }
        
        return "Unknown Source"
    }
    
    // Add to SlimProtoConnectionManagerDelegate extension
    func connectionManagerShouldStorePosition() {
        os_log(.info, log: logger, "🔒 Connection lost - storing current position for recovery")
        
        // Store position through NowPlayingManager
        let nowPlayingManager = audioManager.getNowPlayingManager()
        //nowPlayingManager.storeLockScreenPosition()
    }

    func connectionManagerDidReconnectAfterTimeout() {
        os_log(.info, log: logger, "🔒 Reconnected after timeout - checking for position recovery")
        
        // Wait a moment for connection to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.attemptPositionRecovery()
        }
    }

    // Add this new method for position recovery
    private func attemptPositionRecovery() {
        os_log(.info, log: logger, "🔒 Position recovery temporarily disabled during SlimProto standardization")
        // The server will handle position management through proper SlimProto
        return
    }

    private func performFallbackRecovery(recoveryInfo: (position: Double, wasPlaying: Bool, isValid: Bool), nowPlayingManager: NowPlayingManager) {
        os_log(.info, log: logger, "🔒 Fallback recovery temporarily disabled during SlimProto standardization")
        return
    }


    // Add this new method for seeking via JSON-RPC
    private func sendSeekCommand(to position: Double, completion: @escaping (Bool) -> Void) {
        let playerID = settings.playerMACAddress
        let clampedPosition = max(0, position)
        
        // FIXED: Use correct JSON-RPC format for time seeking
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["time", clampedPosition]]  // ✅ Pass number directly, not as string
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create seek JSON-RPC command")
            completion(false)
            return
        }
        
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        guard let url = URL(string: "http://\(host):\(webPort)/jsonrpc.js") else {
            os_log(.error, log: logger, "Invalid server URL for seek command")
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 8.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self.logger, "Seek command failed: %{public}s", error.localizedDescription)
                    completion(false)
                } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    os_log(.info, log: self.logger, "✅ Seek command sent successfully to %.2f", clampedPosition)
                    completion(true)
                } else {
                    os_log(.error, log: self.logger, "Seek command failed with HTTP error")
                    completion(false)
                }
            }
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Sending seek command to %.2f seconds", clampedPosition)
    }
    
    // MARK: - Volume Control
    func setPlayerVolume(_ volume: Float) {
        os_log(.debug, log: logger, "🔊 Setting player volume: %.2f", volume)
        audioManager.setVolume(volume)
    }

    func getPlayerVolume() -> Float {
        return audioManager.getVolume()
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
