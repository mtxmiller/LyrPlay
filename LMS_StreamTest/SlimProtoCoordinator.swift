// File: SlimProtoCoordinator.swift
// Updated to work with the integrated reference client logic
import Foundation
import os.log

class SlimProtoCoordinator: ObservableObject {
    
    // MARK: - Components
    private let client: SlimProtoClient
    private let commandHandler: SlimProtoCommandHandler
    private let connectionManager: SlimProtoConnectionManager
    private let audioManager: AudioManager
    
    // MARK: - Dependencies
    private let settings = SettingsManager.shared
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoCoordinator")
    
    // MARK: - State Management
    private var statusTimer: Timer?
    
    // MARK: - Initialization
    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        self.client = SlimProtoClient()
        self.commandHandler = SlimProtoCommandHandler()
        self.connectionManager = SlimProtoConnectionManager()
        
        setupDelegation()
        setupAudioCallbacks()
        
        os_log(.info, log: logger, "SlimProtoCoordinator initialized with working reference logic")
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
        // Set up track ended callback (from reference)
        audioManager.onTrackEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.commandHandler.notifyTrackEnded()
            }
        }
        
        // Connect audio manager back to coordinator for lock screen support
        audioManager.slimClient = self
    }
    
    // MARK: - Public Interface
    func connect() {
        os_log(.info, log: logger, "Starting connection...")
        connectionManager.willConnect()
        client.connect()
    }
    
    func disconnect() {
        stopStatusTimer()
        client.disconnect()
        os_log(.info, log: logger, "Disconnected")
    }
    
    func updateServerSettings(host: String, port: UInt16) {
        client.updateServerSettings(host: host, port: port)
    }
    
    // MARK: - Status Timer (from reference, with background awareness)
    private func startStatusTimer() {
        stopStatusTimer()
        
        // Adjust timer interval based on background state
        let interval: TimeInterval
        switch connectionManager.backgroundConnectionStrategy {
        case .normal:
            interval = 10.0  // Normal interval (from reference)
        case .minimal:
            interval = 20.0  // Longer interval in background
        case .suspended:
            interval = 60.0  // Very long interval if suspended
        }
        
        statusTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.sendPeriodicStatus()
        }
        os_log(.info, log: logger, "Status timer started with %.1f second interval", interval)
    }
    
    private func stopStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
    }
    
    private func sendPeriodicStatus() {
        // Update position from audio manager before sending status
        let currentTime = audioManager.getCurrentTime()
        commandHandler.updatePlaybackPosition(currentTime)
        
        // Update client with current position and state
        let isPlaying = audioManager.getPlayerState() == "Playing"
        client.setPlaybackState(isPlaying: isPlaying, position: currentTime)
        
        // Only send periodic heartbeat if we're actually streaming (from reference)
        if commandHandler.streamState != "Stopped" {
            client.sendStatus("STMt") // Send periodic heartbeat
        }
    }
    
    // MARK: - Connection State
    var connectionState: String {
        return connectionManager.connectionState.displayName
    }
    
    var streamState: String {
        return commandHandler.streamState
    }
    
    deinit {
        stopStatusTimer()
        disconnect()
    }
}

// MARK: - SlimProtoClientDelegate
extension SlimProtoCoordinator: SlimProtoClientDelegate {
    
    func slimProtoDidConnect() {
        os_log(.info, log: logger, "✅ Connection established")
        connectionManager.didConnect()
        startStatusTimer() // Start periodic status updates (from reference)
    }
    
    func slimProtoDidDisconnect(error: Error?) {
        os_log(.info, log: logger, "🔌 Connection lost")
        connectionManager.didDisconnect(error: error)
        stopStatusTimer()
    }
    
    func slimProtoDidReceiveCommand(_ command: SlimProtoCommand) {
        // Forward to command handler
        commandHandler.processCommand(command)
    }
}

// MARK: - SlimProtoConnectionManagerDelegate
extension SlimProtoCoordinator: SlimProtoConnectionManagerDelegate {
    
    func connectionManagerShouldReconnect() {
        os_log(.info, log: logger, "🔄 Connection manager requesting reconnection")
        client.connect()
    }
    
    func connectionManagerDidEnterBackground() {
        os_log(.info, log: logger, "📱 Coordinator handling background transition")
        
        // Send immediate status to keep connection alive (from reference)
        if connectionManager.connectionState.isConnected {
            let currentTime = audioManager.getCurrentTime()
            let isCurrentlyPlaying = audioManager.getPlayerState() == "Playing"
            
            // Update client state
            client.setPlaybackState(isPlaying: isCurrentlyPlaying, position: currentTime)
            
            // Send status to server immediately
            client.sendStatus("STMt")
            
            os_log(.info, log: logger, "📱 Sent background status - Playing: %{public}s, Position: %.2f",
                   isCurrentlyPlaying ? "YES" : "NO", currentTime)
        }
        
        // Restart timer with background interval
        if statusTimer != nil {
            startStatusTimer()
        }
    }
    
    func connectionManagerDidEnterForeground() {
        os_log(.info, log: logger, "📱 Coordinator handling foreground transition")
        
        // Check if connection is still alive (from reference)
        if connectionManager.connectionState.isConnected {
            let currentTime = audioManager.getCurrentTime()
            let isCurrentlyPlaying = audioManager.getPlayerState() == "Playing"
            
            // Update client state
            client.setPlaybackState(isPlaying: isCurrentlyPlaying, position: currentTime)
            
            // Send immediate status update
            client.sendStatus("STMt")
            
            os_log(.info, log: logger, "📱 Sent foreground status - Playing: %{public}s, Position: %.2f",
                   isCurrentlyPlaying ? "YES" : "NO", currentTime)
        } else {
            // Connection lost in background - try to reconnect
            os_log(.error, log: logger, "📱 Connection lost in background - reconnecting")
            connect()
        }
        
        // Restart timer with normal interval
        if statusTimer != nil {
            startStatusTimer()
        }
    }
}

// MARK: - SlimProtoCommandHandlerDelegate
extension SlimProtoCoordinator: SlimProtoCommandHandlerDelegate {
    
    func didStartStream(url: String, format: String, startTime: Double) {
        os_log(.info, log: logger, "🎵 Starting audio stream: %{public}s (%{public}s)", url, format)
        
        // Use format-aware playback (from reference)
        if startTime > 0 {
            os_log(.info, log: logger, "🔄 Picking up existing stream at position: %.2f seconds", startTime)
            audioManager.playStreamAtPositionWithFormat(urlString: url, startTime: startTime, format: format)
        } else {
            audioManager.playStreamWithFormat(urlString: url, format: format)
        }
        
        // Update the client with stream start
        client.setPlaybackState(isPlaying: true, position: startTime)
        
        // Fetch metadata for lock screen (from reference)
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
    }
    
    func didResumeStream() {
        os_log(.info, log: logger, "▶️ Resuming audio")
        let currentTime = audioManager.getCurrentTime()
        audioManager.play()
        
        // Update client with actual current position
        client.setPlaybackState(isPlaying: true, position: currentTime)
    }
    
    func didStopStream() {
        os_log(.info, log: logger, "⏹️ Stopping audio")
        audioManager.stop()
        
        // Update client with stop state
        client.setPlaybackState(isPlaying: false, position: 0.0)
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
    }
}

// MARK: - Lock Screen Integration (from reference)
extension SlimProtoCoordinator {
    
    func sendLockScreenCommand(_ command: String) {
        os_log(.info, log: logger, "🔒 Lock Screen command: %{public}s", command)
        
        guard client.connectionState == "Connected" else {
            os_log(.error, log: logger, "Cannot send lock screen command - not connected to server")
            return
        }
        
        switch command.lowercased() {
        case "play":
            // Send unpause/resume status to server (from reference)
            sendJSONRPCCommand("play")
            os_log(.info, log: logger, "✅ Sent resume command to LMS server")
            
        case "pause":
            // Send pause status to server (from reference)
            let currentTime = audioManager.getCurrentTime()
            sendJSONRPCCommand("pause")
            os_log(.info, log: logger, "✅ Sent pause command to LMS server (position: %.2f)", currentTime)
            
        case "stop":
            // Send stop status to server (from reference)
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
    }
    
    private func sendJSONRPCCommand(_ command: String, parameters: [String] = []) {
        // Extract player ID from settings (from reference)
        let playerID = settings.playerMACAddress
        
        var jsonRPCCommand: [String: Any]
        
        switch command.lowercased() {
        case "pause":
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["pause", "1"]] // 1 = pause
            ]
        case "play":
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["pause", "0"]] // 0 = unpause/play
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
        
        // Send API request to LMS (from reference)
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
                    
                    // For skip commands, refresh metadata after a delay (from reference)
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

// MARK: - Metadata Integration (from reference)
extension SlimProtoCoordinator {
    
    private func fetchCurrentTrackMetadata() {
        // Extract player ID (from reference)
        let playerID = settings.playerMACAddress
        
        // Use LMS JSON-RPC API to request current track with comprehensive metadata (from reference)
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                [
                    "status", "-", "1",
                    // Request comprehensive metadata tags (from reference)
                    "tags:u,a,A,l,t,d,e,s,o,r,c,g,p,i,q,y,j,J,K,N,S,w,x,C,G,R,T,I,D,U,F,L,f,n,m,b,v,h,k,z"
                ]
            ]
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create JSON-RPC request")
            return
        }
        
        // Send API request to LMS (from reference)
        let webPort = settings.serverWebPort
        let host = settings.serverHost
        var request = URLRequest(url: URL(string: "http://\(host):\(webPort)/jsonrpc.js")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: self.logger, "JSON-RPC metadata request failed: %{public}s", error.localizedDescription)
                return
            }
            
            guard let data = data else {
                os_log(.error, log: self.logger, "No data received from metadata JSON-RPC")
                return
            }
            
            // Parse response to get current track metadata
            self.parseTrackMetadata(data: data)
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Requesting current track metadata")
    }
    
    private func parseTrackMetadata(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let loop = result["playlist_loop"] as? [[String: Any]],
               let firstTrack = loop.first {
                
                // Extract basic metadata (from reference)
                let trackTitle = firstTrack["title"] as? String ??
                               firstTrack["track"] as? String ?? "LMS Stream"
                
                let trackAlbum = firstTrack["album"] as? String ?? "Lyrion Music Server"
                
                // Extract duration information (from reference)
                let duration = firstTrack["duration"] as? Double ?? 0.0
                os_log(.info, log: logger, "🔍 Track duration from metadata: %.0f seconds", duration)
                
                // Enhanced artist extraction (from reference)
                var trackArtist = "Unknown Artist"
                
                // Method 1: Direct artist field
                if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                    trackArtist = artist
                    os_log(.info, log: logger, "✅ Found artist (direct): %{public}s", artist)
                }
                // Method 2: Album artist field
                else if let albumArtist = firstTrack["albumartist"] as? String, !albumArtist.isEmpty {
                    trackArtist = albumArtist
                    os_log(.info, log: logger, "✅ Found artist (albumartist): %{public}s", albumArtist)
                }
                // Method 3: Contributors array (from reference)
                else if let contributors = firstTrack["contributors"] as? [[String: Any]] {
                    for contributor in contributors {
                        if let role = contributor["role"] as? String,
                           let name = contributor["name"] as? String {
                            os_log(.info, log: logger, "🔍 Contributor: %{public}s (role: %{public}s)", name, role)
                            
                            // Look for artist roles
                            if role.lowercased().contains("artist") ||
                               role.lowercased() == "performer" ||
                               role.lowercased() == "composer" {
                                trackArtist = name
                                os_log(.info, log: logger, "✅ Found artist in contributors: %{public}s (role: %{public}s)", name, role)
                                break
                            }
                        }
                    }
                }
                
                os_log(.info, log: logger, "🎵 Metadata - Title: '%{public}s', Artist: '%{public}s', Album: '%{public}s', Duration: %.0f sec",
                       trackTitle, trackArtist, trackAlbum, duration)
                
                // Create artwork URL if track ID is available (from reference)
                var artworkURL: String? = nil
                if let trackID = firstTrack["id"] as? Int {
                    let webPort = settings.serverWebPort
                    let host = settings.serverHost
                    artworkURL = "http://\(host):\(webPort)/music/\(trackID)/cover.jpg"
                    os_log(.info, log: logger, "🖼️ Artwork URL: %{public}s", artworkURL!)
                } else if let trackIDString = firstTrack["id"] as? String, let trackID = Int(trackIDString) {
                    let webPort = settings.serverWebPort
                    let host = settings.serverHost
                    artworkURL = "http://\(host):\(webPort)/music/\(trackID)/cover.jpg"
                }
                
                // Pass duration to metadata update (from reference)
                DispatchQueue.main.async {
                    self.audioManager.updateTrackMetadata(
                        title: trackTitle,
                        artist: trackArtist,
                        album: trackAlbum,
                        artworkURL: artworkURL,
                        duration: duration  // Include duration
                    )
                    os_log(.info, log: self.logger, "✅ Updated lock screen metadata with duration: '%{public}s' by %{public}s (%.0f sec)",
                           trackTitle, trackArtist, duration)
                }
                
            } else {
                os_log(.error, log: logger, "❌ Failed to parse track metadata response")
            }
        } catch {
            os_log(.error, log: logger, "JSON parsing error for metadata: %{public}s", error.localizedDescription)
        }
    }
}
