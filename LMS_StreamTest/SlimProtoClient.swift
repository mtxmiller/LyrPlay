// File: SlimProtoClient.swift
import Foundation
import CocoaAsyncSocket
import os.log

class SlimProtoClient: NSObject, GCDAsyncSocketDelegate, ObservableObject {
    private var socket: GCDAsyncSocket!
    private let host = "ser5" // Replace with your LMS IP
    private let port: UInt16 = 3483
    private var audioManager: AudioManager
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoClient")
    private var statusTimer: Timer?
    private var isStreamActive = false
    private var currentStreamURL: String?
    private var serverTimestamp: UInt32 = 0  // Store server timestamp for echo back
    private var hasRequestedInitialStatus = false  // Track if we've asked for current status
    private var isPausedByLockScreen = false
    private var lastKnownPosition: Double = 0.0
    
    init(audioManager: AudioManager = AudioManager()) {
        self.audioManager = audioManager
        super.init()
        os_log(.info, log: logger, "SlimProtoClient initializing")
        socket = GCDAsyncSocket(delegate: self, delegateQueue: DispatchQueue(label: "com.lmsstream.socket"))
        os_log(.info, log: logger, "Socket initialized with custom queue")
        
        // Set up callback for when tracks end
        audioManager.onTrackEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.handleTrackEnded()
            }
        }
    }
    
    func connect() {
        os_log(.info, log: logger, "Attempting to connect to %{public}s:%d", host, port)
        do {
            try socket.connect(toHost: host, onPort: port, withTimeout: 30)
            os_log(.info, log: logger, "Connect call executed")
        } catch {
            os_log(.error, log: logger, "Connection error: %{public}s", error.localizedDescription)
        }
    }
    
    func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        os_log(.info, log: logger, "Connected to LMS at %{public}s:%d", host, port)
        sendHello()
        // Start reading server messages - they start with 2-byte length
        socket.readData(toLength: 2, withTimeout: 30, tag: 0)
        os_log(.info, log: logger, "Read data initiated after connect - expecting 2-byte length header")
        
        // Start periodic status updates
        startStatusTimer()
        
        // *** NEW: Request current status after connecting to pick up existing streams ***
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !self.hasRequestedInitialStatus {
                self.hasRequestedInitialStatus = true
                self.sendStatus("STMt") // Request current status to see if already playing
                os_log(.info, log: self.logger, "🔄 Requested initial status to detect existing streams")
            }
        }
    }
    
    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            // Only send periodic heartbeat if we're actually streaming
            if self.isStreamActive {
                self.sendStatus("STMt") // Send periodic heartbeat
            }
        }
        os_log(.info, log: logger, "Started status timer (10 second intervals)")
    }
    
    func sendHello() {
        os_log(.info, log: logger, "Sending enhanced HELO message with iOS-optimized capabilities")
        
        // Create a proper HELO message according to SlimProto spec
        // Change deviceID to softsqueeze for better app compatibility
        let deviceID: UInt8 = 12  // softsqueeze (was 8 = squeezeslave)
        let revision: UInt8 = 1
        let macAddress: [UInt8] = [0x00, 0x04, 0x20, 0x12, 0x34, 0x56] // Keep your existing MAC
        
        var helloData = Data()
        
        // Device ID (1 byte)
        helloData.append(deviceID)
        
        // Revision (1 byte)
        helloData.append(revision)
        
        // MAC address (6 bytes)
        helloData.append(Data(macAddress))
        
        // UUID (16 bytes) - optional, using zeros
        helloData.append(Data(repeating: 0, count: 16))
        
        // WLan channel list (2 bytes) - optional, 0x07ff for US channels
        let wlanChannels: UInt16 = 0x07ff
        helloData.append(Data([UInt8(wlanChannels >> 8), UInt8(wlanChannels & 0xff)]))
        
        // Bytes received (8 bytes) - optional, starting at 0
        helloData.append(Data(repeating: 0, count: 8))
        
        // Language (2 bytes) - optional, "en"
        helloData.append("en".data(using: .ascii) ?? Data([0x65, 0x6e]))
        
        // *** REPLACE YOUR OLD CAPABILITIES WITH THIS ***
        // Declare formats in order of preference - what AVPlayer handles best
        let capabilities = "aac,alac,mp3,Model=LMSStreamApp,ModelName=LMS Stream for iOS,MaxSampleRate=48000,Channels=2,SampleSize=16"
        
        if let capabilitiesData = capabilities.data(using: .utf8) {
            helloData.append(capabilitiesData)
            os_log(.info, log: logger, "Added enhanced capabilities: %{public}s", capabilities)
        }
        
        // Create the full message with header (keep existing code)
        let command = "HELO".data(using: .ascii)!
        let length = UInt32(helloData.count).bigEndian
        let lengthData = withUnsafeBytes(of: length) { Data($0) }
        
        var fullMessage = Data()
        fullMessage.append(command)      // 4 bytes: "HELO"
        fullMessage.append(lengthData)   // 4 bytes: length
        fullMessage.append(helloData)    // payload
        
        socket.write(fullMessage, withTimeout: 30, tag: 1)
        os_log(.info, log: logger, "Enhanced HELO message sent - requesting AAC/ALAC with MP3 fallback")
    }
    
    func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        if tag == 0 {
            // We read the 2-byte length header from server
            guard data.count >= 2 else {
                os_log(.error, log: logger, "Length header too short: %d bytes", data.count)
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
                return
            }
            
            // Parse 2-byte length in network order
            let messageLength = data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            os_log(.info, log: logger, "Server message length: %d bytes", messageLength)
            
            if messageLength > 0 && messageLength < 10000 { // Sanity check
                // Read the complete message (command + data)
                socket.readData(toLength: UInt(messageLength), withTimeout: 30, tag: 1)
            } else {
                os_log(.error, log: logger, "Invalid message length: %d", messageLength)
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
            }
        } else if tag == 1 {
            // We read the complete server message (4-byte command + payload)
            guard data.count >= 4 else {
                os_log(.error, log: logger, "Message too short for command: %d bytes", data.count)
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
                return
            }
            
            let commandData = data.subdata(in: 0..<4)
            let payloadData = data.count > 4 ? data.subdata(in: 4..<data.count) : Data()
            
            guard let command = String(data: commandData, encoding: .ascii) else {
                os_log(.error, log: logger, "Failed to decode command from message")
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
                return
            }
            
            os_log(.info, log: logger, "Server command: %{public}s, payload: %d bytes", command, payloadData.count)
            processServerCommand(command, payload: payloadData)
            
            // Continue reading next message
            socket.readData(toLength: 2, withTimeout: 30, tag: 0)
        }
    }
    
    private func processServerCommand(_ command: String, payload: Data) {
        switch command {
        case "strm":
            if payload.count >= 24 {
                let streamCommand = payload[0]
                let autostart = payload[1]
                let format = payload[2]
                
                let commandChar = String(UnicodeScalar(streamCommand) ?? "?")
                os_log(.info, log: logger, "🎵 Server strm - command: '%{public}s' (%d), format: %d (0x%02x)",
                       commandChar, streamCommand, format, format)
                
                // *** ENHANCED FORMAT HANDLING ***
                var formatName = "Unknown"
                var shouldAccept = false
                
                switch format {
                case 97:  // 'a' = AAC
                    formatName = "AAC"
                    shouldAccept = true
                    os_log(.info, log: logger, "✅ Server offering AAC - perfect for iOS!")
                    
                case 65:  // 'A' = ALAC
                    formatName = "ALAC"
                    shouldAccept = true
                    os_log(.info, log: logger, "✅ Server offering ALAC - excellent for iOS!")
                    
                case 109: // 'm' = MP3
                    formatName = "MP3"
                    shouldAccept = true
                    os_log(.info, log: logger, "✅ Server offering MP3 - acceptable fallback")
                    
                case 102: // 'f' = FLAC
                    formatName = "FLAC"
                    shouldAccept = false
                    os_log(.info, log: logger, "❌ Server offering FLAC - requesting transcode to AAC")
                    
                case 112: // 'p' = PCM
                    formatName = "PCM"
                    shouldAccept = true
                    os_log(.info, log: logger, "✅ Server offering PCM - iOS can handle this")
                    
                default:
                    os_log(.error, log: logger, "❓ Unknown format: %d (0x%02x)", format, format)
                    shouldAccept = false
                }
                
                if !shouldAccept {
                    // Reject this format and request transcoding
                    os_log(.info, log: logger, "🔄 Rejecting %{public}s format, requesting AAC transcode", formatName)
                    sendStatus("STMn") // Not supported - triggers format renegotiation
                    return
                }
                
                // Extract server elapsed time for stream pickup (keep your existing code)
                let serverElapsedTime = extractServerElapsedTime(from: payload)
                
                // Extract HTTP request from remaining payload
                if payload.count > 24 {
                    let httpData = payload.subdata(in: 24..<payload.count)
                    if let httpRequest = String(data: httpData, encoding: .utf8) {
                        os_log(.info, log: logger, "HTTP request for %{public}s: %{public}s", formatName, httpRequest)
                        
                        // Parse the URL from the HTTP request
                        if let url = extractURLFromHTTPRequest(httpRequest) {
                            os_log(.info, log: logger, "✅ Accepting %{public}s stream: %{public}s", formatName, url)
                            
                            // Handle different stream commands
                            switch streamCommand {
                            case UInt8(ascii: "s"): // start
                                os_log(.info, log: logger, "Starting %{public}s stream playback", formatName)
                                isPausedByLockScreen = false
                                currentStreamURL = url
                                isStreamActive = true
                                
                                // Use format-aware playback
                                if serverElapsedTime > 0 {
                                    os_log(.info, log: logger, "🔄 Picking up existing stream at position: %.2f seconds", serverElapsedTime)
                                    audioManager.playStreamAtPositionWithFormat(urlString: url, startTime: serverElapsedTime, format: formatName)
                                } else {
                                    audioManager.playStreamWithFormat(urlString: url, format: formatName)
                                }
                                
                                // *** ADD THIS: Fetch metadata for lock screen ***
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    self.fetchCurrentTrackMetadata()
                                }
                                
                                sendStatus("STMc") // Connect - acknowledge stream start
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    self.sendStatus("STMs") // Stream started
                                }
                                
                            // Keep all your existing cases for pause, unpause, stop, etc.
                            case UInt8(ascii: "p"): // pause
                                os_log(.info, log: logger, "⏸️ Server pause command")
                                isPausedByLockScreen = true
                                lastKnownPosition = audioManager.getCurrentTime()
                                audioManager.pause()
                                sendStatus("STMp") // Paused
                                
                            case UInt8(ascii: "u"): // unpause
                                os_log(.info, log: logger, "▶️ Server unpause command")
                                isPausedByLockScreen = false
                                audioManager.play()
                                sendStatus("STMr") // Resume
                                
                            case UInt8(ascii: "q"): // stop
                                os_log(.info, log: logger, "⏹️ Server stop command")
                                isPausedByLockScreen = false
                                audioManager.stop()
                                isStreamActive = false
                                currentStreamURL = nil
                                sendStatus("STMf") // Flushed/stopped
                                
                            case UInt8(ascii: "t"): // status request
                                os_log(.debug, log: logger, "🔄 Server status request (with HTTP data)")
                                if isPausedByLockScreen {
                                    sendStatus("STMp") // Pause status
                                } else {
                                    sendStatus("STMt") // Timer/heartbeat status
                                }
                                
                            case UInt8(ascii: "f"): // flush
                                os_log(.info, log: logger, "🗑️ Server flush command")
                                isPausedByLockScreen = false
                                audioManager.stop()
                                isStreamActive = false
                                currentStreamURL = nil
                                sendStatus("STMf") // Flushed
                                
                            default:
                                sendStatus("STMt") // Generic status
                            }
                        } else {
                            sendStatus("STMn") // Not supported/error
                        }
                    } else {
                        sendStatus("STMn") // Not supported/error
                    }

                } else {
                    // Handle commands that don't need URLs (like pause, stop, status, etc.)
                    os_log(.error, log: logger, "⚠️ Stream command '%{public}s' has no HTTP data - handling as control command", commandChar)
                    
                    // For status requests, extract the server timestamp from the payload
                    if streamCommand == UInt8(ascii: "t") && payload.count >= 24 {
                        // Extract server timestamp from replay_gain field (bytes 16-19)
                        let timestampData = payload.subdata(in: 16..<20)
                        serverTimestamp = timestampData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                        os_log(.debug, log: logger, "Extracted server timestamp: %d", serverTimestamp)
                    }
                    
                    switch streamCommand {
                    case UInt8(ascii: "s"): // start - but no URL!
                        os_log(.error, log: logger, "🚨 Server sent START command but no HTTP data! This shouldn't happen.")
                        sendStatus("STMn") // Not supported - request proper stream
                    case UInt8(ascii: "p"): // pause
                        os_log(.info, log: logger, "⏸️ Server pause command (no HTTP data)")
                        // *** CRITICAL: Set pause state for server-initiated pause ***
                        isPausedByLockScreen = true
                        lastKnownPosition = audioManager.getCurrentTime()
                        audioManager.pause()
                        sendStatus("STMp")
                    case UInt8(ascii: "u"): // unpause
                        os_log(.info, log: logger, "▶️ Server unpause command (no HTTP data)")
                        // *** CLEAR PAUSE STATE WHEN SERVER UNPAUSES ***
                        isPausedByLockScreen = false
                        audioManager.play()
                        sendStatus("STMr")
                    case UInt8(ascii: "q"): // stop
                        os_log(.info, log: logger, "⏹️ Server stop command (no HTTP data)")
                        // *** CLEAR PAUSE STATE WHEN STOPPING ***
                        isPausedByLockScreen = false
                        audioManager.stop()
                        isStreamActive = false
                        sendStatus("STMf")
                    case UInt8(ascii: "t"): // status request
                        os_log(.debug, log: logger, "🔄 Server status request (no HTTP data)")
                        
                        // *** CRITICAL: Respond based on our ACTUAL state ***
                        if isPausedByLockScreen {
                            sendStatus("STMp") // Send PAUSE status
                            os_log(.info, log: logger, "📍 Responding to status request with PAUSE status")
                        } else {
                            sendStatus("STMt") // Timer/heartbeat status
                            os_log(.info, log: logger, "📍 Responding to status request with TIMER status")
                        }
                    case UInt8(ascii: "f"): // flush
                        os_log(.info, log: logger, "🗑️ Server flush command (no HTTP data)")
                        // *** CLEAR PAUSE STATE WHEN FLUSHING ***
                        isPausedByLockScreen = false
                        audioManager.stop()
                        isStreamActive = false
                        sendStatus("STMf")
                    default:
                        os_log(.error, log: logger, "❓ Unknown stream command: '%{public}s' (%d)", commandChar, streamCommand)
                        sendStatus("STMt") // Default to timer status
                    }
                }
            } else {
                sendStatus("STMn") // Not supported
            }
        case "audg":
            sendStatus("STMt") // Acknowledge with heartbeat
        case "aude":
            sendStatus("STMt") // Acknowledge with heartbeat
        case "stat":
            // *** RESPOND TO STAT REQUESTS BASED ON ACTUAL STATE ***
            if isPausedByLockScreen {
                sendStatus("STMp") // Send pause status when paused
                os_log(.info, log: logger, "📍 STAT request - responding with PAUSE status")
            } else {
                sendStatus("STMt") // Timer/heartbeat
            }
        case "vers":
            sendStatus("STMt") // Acknowledge with heartbeat
        case "vfdc":
            // *** RESPOND TO VFD COMMANDS BASED ON ACTUAL STATE ***
            if isPausedByLockScreen {
                sendStatus("STMp") // Send pause status when paused
            } else {
                sendStatus("STMt")
            }
        case "grfe":
            sendStatus("STMt")
        case "grfb":
            sendStatus("STMt")
        default:
            sendStatus("STMt")
        }
    }
    
    // *** NEW: Extract elapsed time from server stream command ***
    private func extractServerElapsedTime(from payload: Data) -> Double {
        // In SlimProto, the elapsed time might be in the replay_gain field (bytes 16-19)
        // or in the format-specific data. Let's try to extract it.
        guard payload.count >= 24 else { return 0.0 }
        
        // Try to extract from replay_gain field (bytes 16-19) as elapsed seconds
        let elapsedData = payload.subdata(in: 16..<20)
        let elapsedSeconds = elapsedData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // *** FIX: Much more restrictive sanity check ***
        // Elapsed time shouldn't be more than 1 hour for most tracks
        if elapsedSeconds > 0 && elapsedSeconds < 3600 { // Max 1 hour
            os_log(.info, log: logger, "🔄 Extracted valid server elapsed time: %d seconds", elapsedSeconds)
            return Double(elapsedSeconds)
        } else if elapsedSeconds > 0 {
            os_log(.error, log: logger, "⚠️ Server elapsed time seems too high: %d seconds - ignoring", elapsedSeconds)
        }
        
        return 0.0
    }
    
    private func parseTrackMetadata(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let loop = result["playlist_loop"] as? [[String: Any]],
               let firstTrack = loop.first {
                
                // Extract basic metadata
                let trackTitle = firstTrack["title"] as? String ??
                               firstTrack["track"] as? String ?? "LMS Stream"
                
                let trackAlbum = firstTrack["album"] as? String ?? "Lyrion Music Server"
                
                // *** NEW: Extract duration information ***
                let duration = firstTrack["duration"] as? Double ?? 0.0
                os_log(.info, log: logger, "🔍 Track duration from metadata: %.0f seconds", duration)
                
                // Enhanced artist extraction (keep your existing logic)
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
                // Method 3: Track artist field
                else if let trackArtistField = firstTrack["trackartist"] as? String, !trackArtistField.isEmpty {
                    trackArtist = trackArtistField
                    os_log(.info, log: logger, "✅ Found artist (trackartist): %{public}s", trackArtistField)
                }
                // Method 4: Check for band field
                else if let band = firstTrack["band"] as? String, !band.isEmpty {
                    trackArtist = band
                    os_log(.info, log: logger, "✅ Found artist (band): %{public}s", band)
                }
                // Method 5: Check contributors array (keep your existing logic)
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
                
                // Create artwork URL if track ID is available
                var artworkURL: String? = nil
                if let trackID = firstTrack["id"] as? Int {
                    artworkURL = "http://\(host):9000/music/\(trackID)/cover.jpg"
                    os_log(.info, log: logger, "🖼️ Artwork URL: %{public}s", artworkURL!)
                } else if let trackIDString = firstTrack["id"] as? String, let trackID = Int(trackIDString) {
                    artworkURL = "http://\(host):9000/music/\(trackID)/cover.jpg"
                }
                
                // *** UPDATED: Pass duration to metadata update ***
                DispatchQueue.main.async {
                    self.audioManager.updateTrackMetadata(
                        title: trackTitle,
                        artist: trackArtist,
                        album: trackAlbum,
                        artworkURL: artworkURL,
                        duration: duration  // *** NEW: Include duration ***
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
    
    private func fetchCurrentTrackMetadata() {
        // Extract player ID (use your existing MAC address)
        let playerID = "00:04:20:12:34:56"
        
        // Use LMS JSON-RPC API to request current track with comprehensive metadata
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                [
                    "status", "-", "1",
                    // Request comprehensive metadata tags
                    "tags:u,a,A,l,t,d,e,s,o,r,c,g,p,i,q,y,j,J,K,N,S,w,x,C,G,R,T,I,D,U,F,L,f,n,m,b,v,h,k,z"
                ]
            ]
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create JSON-RPC request")
            return
        }
        
        // Send API request to LMS
        var request = URLRequest(url: URL(string: "http://\(host):9000/jsonrpc.js")!)
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

    
    private func extractURLFromHTTPRequest(_ httpRequest: String) -> String? {
        // Parse HTTP request like "GET /stream.mp3?player=xx:xx:xx:xx:xx:xx HTTP/1.0"
        let lines = httpRequest.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        
        let path = parts[1]
        let fullURL = "http://\(host):9000\(path)"
        
        os_log(.info, log: logger, "🔍 Extracted stream URL: %{public}s", fullURL)
        
        // Return the URL directly - server has already provided the right format
        // based on our capabilities negotiation in sendHello()
        return fullURL
    }
    
     
    func sendLockScreenCommand(_ command: String) {
        os_log(.info, log: logger, "🔒 Lock Screen command: %{public}s", command)
        
        guard socket.isConnected else {
            os_log(.error, log: logger, "Cannot send lock screen command - not connected to server")
            return
        }
        
        switch command.lowercased() {
        case "play":
            // Send unpause/resume status to server
            isPausedByLockScreen = false
            sendStatus("STMr") // Resume
            sendJSONRPCCommand("play")
            os_log(.info, log: logger, "✅ Sent resume status to LMS server")
            
        case "pause":
            // Track that we're paused and save position
            isPausedByLockScreen = true
            lastKnownPosition = audioManager.getCurrentTime()
            sendStatus("STMp") // Paused
            sendJSONRPCCommand("pause")
            os_log(.info, log: logger, "✅ Sent pause status to LMS server (position: %.2f)", lastKnownPosition)
            
        case "stop":
            // Send stop status to server
            isPausedByLockScreen = false
            lastKnownPosition = 0.0
            sendStatus("STMf") // Flushed/stopped
            sendJSONRPCCommand("stop")
            isStreamActive = false
            currentStreamURL = nil
            os_log(.info, log: logger, "✅ Sent stop status to LMS server")
            
        // *** NEW: Handle skip commands ***
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
        // Extract player ID from current connection or use default
        let playerID = "00:04:20:12:34:56" // Your MAC address from HELO
        
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
        // *** NEW: Handle playlist navigation ***
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
        var request = URLRequest(url: URL(string: "http://\(host):9000/jsonrpc.js")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0 // Quick timeout for UI responsiveness
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self.logger, "JSON-RPC %{public}s command failed: %{public}s", command, error.localizedDescription)
                } else {
                    os_log(.info, log: self.logger, "✅ JSON-RPC %{public}s command sent successfully", command)
                    
                    // *** NEW: For skip commands, refresh metadata after a delay ***
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

    
    
    
    private func sendFormatRequest() {
        os_log(.info, log: logger, "🎵 Requesting MP3 format from server")
        
        // Send a simple "not supported" response to reject FLAC
        // This should cause the server to try a different format
        sendStatus("STMn") // Not supported - triggers format renegotiation
        
        os_log(.info, log: logger, "🎵 Format rejection sent - server should retry with MP3")
    }
    
    private func sendStatus(_ code: String) {
        os_log(.info, log: logger, "Sending STAT with code: %{public}s", code)
        
        // *** CRITICAL: Use frozen position when paused ***
        let currentTime: Double
        if isPausedByLockScreen && (code == "STMp") {
            currentTime = lastKnownPosition // Use frozen position for pause status
            os_log(.info, log: logger, "🔒 Using frozen position for PAUSE status: %.2f", currentTime)
        } else if code == "STMt" && !isPausedByLockScreen {
            currentTime = getCurrentPlaybackTime() // Live position for timer status
        } else {
            currentTime = lastKnownPosition // Default to last known when paused
        }
        
        // Create a minimal but correct STAT message
        var statusData = Data()
        
        // Event Code (4 bytes) - like "STMt", "STMp", etc.
        let eventCode = code.padding(toLength: 4, withPad: " ", startingAt: 0)
        statusData.append(eventCode.data(using: .ascii) ?? Data())
        
        // Number of consecutive CRLF (1 byte)
        statusData.append(0)
        
        // MAS Initialized (1 byte) - 'm' for initialized
        statusData.append(UInt8(ascii: "m"))
        
        // *** CRITICAL: MAS Mode reflects ACTUAL pause state ***
        // MAS Mode (1 byte) - According to SlimProto spec:
        if isPausedByLockScreen || code == "STMp" {
            statusData.append(UInt8(ascii: "p")) // 'p' = paused
            os_log(.info, log: logger, "🔒 MAS Mode set to PAUSED ('p')")
        } else {
            statusData.append(0) // 0 = playing/stopped
            os_log(.info, log: logger, "▶️ MAS Mode set to PLAYING (0)")
        }
        
        // Buffer size (4 bytes) - fake reasonable value
        let bufferSize: UInt32 = 262144  // 256KB
        statusData.append(Data([
            UInt8((bufferSize >> 24) & 0xff),
            UInt8((bufferSize >> 16) & 0xff),
            UInt8((bufferSize >> 8) & 0xff),
            UInt8(bufferSize & 0xff)
        ]))
        
        // Buffer fullness (4 bytes) - when paused, show buffer as empty/minimal
        let bufferFullness: UInt32 = isPausedByLockScreen ? 0 : 131072  // 0 when paused, 128KB when playing
        statusData.append(Data([
            UInt8((bufferFullness >> 24) & 0xff),
            UInt8((bufferFullness >> 16) & 0xff),
            UInt8((bufferFullness >> 8) & 0xff),
            UInt8(bufferFullness & 0xff)
        ]))
        
        // Bytes received (8 bytes) - estimate based on time and bitrate
        let estimatedBitrate: UInt64 = 320000 // 320kbps
        let safeCurrentTime = currentTime.isFinite ? max(0, currentTime) : 0.0
        let bytesReceived: UInt64 = UInt64(safeCurrentTime * Double(estimatedBitrate) / 8.0)
        statusData.append(Data([
            UInt8((bytesReceived >> 56) & 0xff),
            UInt8((bytesReceived >> 48) & 0xff),
            UInt8((bytesReceived >> 40) & 0xff),
            UInt8((bytesReceived >> 32) & 0xff),
            UInt8((bytesReceived >> 24) & 0xff),
            UInt8((bytesReceived >> 16) & 0xff),
            UInt8((bytesReceived >> 8) & 0xff),
            UInt8(bytesReceived & 0xff)
        ]))
        
        // Wireless signal strength (2 bytes) - 100 = wired
        statusData.append(Data([0x00, 0x64]))
        
        // Jiffies (4 bytes) - simple timestamp counter
        let jiffies = UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 4294967.0) * 1000)
        statusData.append(Data([
            UInt8((jiffies >> 24) & 0xff),
            UInt8((jiffies >> 16) & 0xff),
            UInt8((jiffies >> 8) & 0xff),
            UInt8(jiffies & 0xff)
        ]))
        
        // Output buffer size (4 bytes)
        let outputBufferSize: UInt32 = 8192
        statusData.append(Data([
            UInt8((outputBufferSize >> 24) & 0xff),
            UInt8((outputBufferSize >> 16) & 0xff),
            UInt8((outputBufferSize >> 8) & 0xff),
            UInt8(outputBufferSize & 0xff)
        ]))
        
        // Output buffer fullness (4 bytes) - when paused, output buffer should be empty
        let outputBufferFullness: UInt32 = isPausedByLockScreen ? 0 : 4096
        statusData.append(Data([
            UInt8((outputBufferFullness >> 24) & 0xff),
            UInt8((outputBufferFullness >> 16) & 0xff),
            UInt8((outputBufferFullness >> 8) & 0xff),
            UInt8(outputBufferFullness & 0xff)
        ]))
        
        // *** TIMING FIELDS: Different handling for STMp vs STMt ***
        if code == "STMt" || code == "STMp" {
            // Elapsed seconds (4 bytes)
            let safeCurrentTime = currentTime.isFinite ? max(0, currentTime) : 0.0
            let elapsedSeconds = UInt32(safeCurrentTime)
            statusData.append(Data([
                UInt8((elapsedSeconds >> 24) & 0xff),
                UInt8((elapsedSeconds >> 16) & 0xff),
                UInt8((elapsedSeconds >> 8) & 0xff),
                UInt8(elapsedSeconds & 0xff)
            ]))
            
            // Voltage (2 bytes)
            statusData.append(Data([0x00, 0x00]))
            
            // Elapsed milliseconds (4 bytes)
            let elapsedMs = UInt32(safeCurrentTime * 1000)
            statusData.append(Data([
                UInt8((elapsedMs >> 24) & 0xff),
                UInt8((elapsedMs >> 16) & 0xff),
                UInt8((elapsedMs >> 8) & 0xff),
                UInt8(elapsedMs & 0xff)
            ]))
            
            // Server timestamp (4 bytes) - echo back
            statusData.append(Data([
                UInt8((serverTimestamp >> 24) & 0xff),
                UInt8((serverTimestamp >> 16) & 0xff),
                UInt8((serverTimestamp >> 8) & 0xff),
                UInt8(serverTimestamp & 0xff)
            ]))
            
            // Error code (2 bytes)
            statusData.append(Data([0x00, 0x00]))
            
            if code == "STMp" {
                os_log(.info, log: logger, "STAT sent - PAUSE STATUS with position: %.2f seconds (raw: %d ms)", safeCurrentTime, elapsedMs)
            } else {
                os_log(.info, log: logger, "STAT sent - TIMER STATUS with elapsed time: %.2f seconds (raw: %d ms)", safeCurrentTime, elapsedMs)
            }
        } else {
            // For other status codes, don't include timing fields
            os_log(.info, log: logger, "STAT sent with code: %{public}s (no timing)", code)
        }
        
        // Create full message
        let command = "STAT".data(using: .ascii)!
        let length = UInt32(statusData.count).bigEndian
        let lengthData = withUnsafeBytes(of: length) { Data($0) }
        
        var fullMessage = Data()
        fullMessage.append(command)
        fullMessage.append(lengthData)
        fullMessage.append(statusData)
        
        socket.write(fullMessage, withTimeout: 30, tag: 2)
    }
    
    private func getCurrentPlaybackTime() -> Double {
        // Get current playback time from audio manager
        let currentTime = audioManager.getCurrentTime()
        
        // Also check if track ended manually
        if isStreamActive && audioManager.checkIfTrackEnded() {
            handleTrackEnded()
        }
        
        // Add some bounds checking to prevent crazy values
        if currentTime < 0 || currentTime > 86400 { // Max 24 hours
            return 0.0
        }
        
        return currentTime
    }
    
    private func handleTrackEnded() {
        os_log(.info, log: logger, "Track ended - sending STMd to request next track")
        isStreamActive = false
        currentStreamURL = nil
        sendStatus("STMd") // Decoder ready - request next track
    }
    
    func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        if let error = err {
            os_log(.error, log: logger, "Disconnected with error: %{public}s", error.localizedDescription)
        } else {
            os_log(.info, log: logger, "Disconnected gracefully")
        }
        
        // Stop status timer
        statusTimer?.invalidate()
        statusTimer = nil
        
        // Reset connection state
        hasRequestedInitialStatus = false
        
        // Attempt to reconnect after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.connect()
        }
    }
}
