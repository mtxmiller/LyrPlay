// File: SlimProtoClient.swift
import Foundation
import CocoaAsyncSocket
import os.log

class SlimProtoClient: NSObject, GCDAsyncSocketDelegate, ObservableObject {
    private var socket: GCDAsyncSocket!
    private let host = "192.168.1.8" // Replace with your LMS IP
    private let port: UInt16 = 3483
    private var audioManager: AudioManager
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoClient")
    private var statusTimer: Timer?
    private var isStreamActive = false
    private var currentStreamURL: String?
    private var serverTimestamp: UInt32 = 0  // Store server timestamp for echo back
    private var hasRequestedInitialStatus = false  // Track if we've asked for current status
    
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
        os_log(.info, log: logger, "Sending HELO message")
        
        // Create a proper HELO message according to SlimProto spec
        // DeviceID: '3' = softsqueeze, '8' = squeezeslave (good choice for app)
        let deviceID: UInt8 = 8  // squeezeslave
        let revision: UInt8 = 1
        let macAddress: [UInt8] = [0x00, 0x04, 0x20, 0x12, 0x34, 0x56] // Fake but valid MAC
        
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
        
        // Add capabilities string to tell server what formats we support
        // FORCE transcoding by only claiming MP3 support
        let capabilities = "mp3,Model=SqueezeLite,ModelName=LMSStream,MaxSampleRate=48000"
        if let capabilitiesData = capabilities.data(using: .utf8) {
            helloData.append(capabilitiesData)
            os_log(.info, log: logger, "Added capabilities: %{public}s", capabilities)
        }
        
        // Create the full message with header
        let command = "HELO".data(using: .ascii)!
        let length = UInt32(helloData.count).bigEndian
        let lengthData = withUnsafeBytes(of: length) { Data($0) }
        
        var fullMessage = Data()
        fullMessage.append(command)      // 4 bytes: "HELO"
        fullMessage.append(lengthData)   // 4 bytes: length
        fullMessage.append(helloData)    // payload
        
        socket.write(fullMessage, withTimeout: 30, tag: 1)
        os_log(.info, log: logger, "HELO message sent, total length: %d, payload length: %d", fullMessage.count, helloData.count)
        os_log(.debug, log: logger, "DeviceID: %d, Revision: %d, MAC: %02x:%02x:%02x:%02x:%02x:%02x",
               deviceID, revision, macAddress[0], macAddress[1], macAddress[2], macAddress[3], macAddress[4], macAddress[5])
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
                
                // *** LOG BOTH FORMAT AND COMMAND FOR DEBUGGING ***
                let commandChar = String(UnicodeScalar(streamCommand) ?? "?")
                os_log(.info, log: logger, "🎵 Server strm - command: '%{public}s' (%d), format: %d (0x%02x)",
                       commandChar, streamCommand, format, format)
                
                // *** CHECK IF SERVER IS SENDING FLAC FORMAT ***
                if format == 102 { // 'f' = FLAC format
                    os_log(.error, log: logger, "⚠️ Server wants to send FLAC - will modify URL for transcoding")
                    // Don't reject - accept it but modify the URL later
                }
                
                // *** ACCEPT MP3 FORMAT ***
                if format == 109 { // 'm' = MP3 format
                    os_log(.info, log: logger, "✅ Server responding with MP3 format - proceeding")
                } else if format != 102 { // Not FLAC and not MP3
                    os_log(.error, log: logger, "⚠️ Unknown format byte: %d (0x%02x)", format, format)
                }
                
                // *** LOG PAYLOAD SIZE TO UNDERSTAND WHAT WE'RE GETTING ***
                os_log(.info, log: logger, "🔍 Stream payload size: %d bytes (need >24 for HTTP data)", payload.count)
                
                // *** NEW: Extract server timestamp and elapsed time for stream pickup ***
                let serverElapsedTime = extractServerElapsedTime(from: payload)
                
                // *** DEBUG: Log payload bytes for troubleshooting ***
                if payload.count >= 24 {
                    let replayGainBytes = payload.subdata(in: 16..<20)
                    let rawValue = replayGainBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    os_log(.debug, log: logger, "🔍 Payload replay_gain bytes 16-19: %02x %02x %02x %02x = %d seconds",
                           replayGainBytes[0], replayGainBytes[1], replayGainBytes[2], replayGainBytes[3], rawValue)
                }
                
                // Extract HTTP request from remaining payload
                if payload.count > 24 {
                    let httpData = payload.subdata(in: 24..<payload.count)
                    if let httpRequest = String(data: httpData, encoding: .utf8) {
                        os_log(.info, log: logger, "HTTP request: %{public}s", httpRequest)
                        
                        // Parse the URL from the HTTP request
                        if let url = extractURLFromHTTPRequest(httpRequest) {
                            os_log(.info, log: logger, "Extracted stream URL: %{public}s", url)
                            
                            // Handle different stream commands
                            switch streamCommand {
                            case UInt8(ascii: "s"): // start
                                os_log(.info, log: logger, "Starting stream playback")
                                currentStreamURL = url
                                isStreamActive = true
                                
                                // *** NEW: Start stream with server elapsed time for sync ***
                                if serverElapsedTime > 0 {
                                    os_log(.info, log: logger, "🔄 Picking up existing stream at position: %.2f seconds", serverElapsedTime)
                                    audioManager.playStreamAtPosition(urlString: url, startTime: serverElapsedTime)
                                } else {
                                    audioManager.playStream(urlString: url)
                                }
                                
                                sendStatus("STMc") // Connect - acknowledge stream start
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    self.sendStatus("STMs") // Stream started
                                }
                            case UInt8(ascii: "p"): // pause
                                os_log(.info, log: logger, "Pausing stream")
                                audioManager.pause()
                                sendStatus("STMp") // Paused
                            case UInt8(ascii: "u"): // unpause
                                os_log(.info, log: logger, "Unpausing stream")
                                audioManager.play()
                                sendStatus("STMr") // Resume
                            case UInt8(ascii: "q"): // stop
                                os_log(.info, log: logger, "Stopping stream")
                                audioManager.stop()
                                isStreamActive = false
                                currentStreamURL = nil
                                sendStatus("STMf") // Flushed/stopped
                            case UInt8(ascii: "t"): // status request
                                sendStatus("STMt") // Timer/status
                            case UInt8(ascii: "f"): // flush
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
                        os_log(.info, log: logger, "⏸️ Server pause command")
                        audioManager.pause()
                        sendStatus("STMp")
                    case UInt8(ascii: "u"): // unpause
                        os_log(.info, log: logger, "▶️ Server unpause command")
                        audioManager.play()
                        sendStatus("STMr")
                    case UInt8(ascii: "q"): // stop
                        os_log(.info, log: logger, "⏹️ Server stop command")
                        audioManager.stop()
                        isStreamActive = false
                        sendStatus("STMf")
                    case UInt8(ascii: "t"): // status request
                        os_log(.debug, log: logger, "🔄 Server status request")
                        sendStatus("STMt") // Just send timer/heartbeat status
                    case UInt8(ascii: "f"): // flush
                        os_log(.info, log: logger, "🗑️ Server flush command")
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
            sendStatus("STMt") // Timer/heartbeat
        case "vers":
            sendStatus("STMt") // Acknowledge with heartbeat
        case "vfdc":
            sendStatus("STMt")
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
    
    private func extractURLFromHTTPRequest(_ httpRequest: String) -> String? {
        // Parse HTTP request like "GET /stream.mp3?player=xx:xx:xx:xx:xx:xx HTTP/1.0"
        let lines = httpRequest.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        
        let path = parts[1]
        
        os_log(.info, log: logger, "🔍 Original stream path: %{public}s", path)
        
        // *** NEW APPROACH: Use LMS JSON-RPC to get transcoded URL ***
        requestTranscodedURL(originalPath: path)
        
        // For now, return the original URL while we wait for the API response
        let originalURL = "http://\(host):9000\(path)"
        os_log(.info, log: logger, "⚠️ Using original URL temporarily: %{public}s", originalURL)
        return originalURL
    }
    
    private func requestTranscodedURL(originalPath: String) {
        // Extract player ID from path
        var playerID = "00:04:20:12:34:56"
        if let playerRange = originalPath.range(of: "player=([^&]+)", options: .regularExpression) {
            let match = String(originalPath[playerRange])
            playerID = match.replacingOccurrences(of: "player=", with: "")
        }
        
        // Use LMS JSON-RPC API to request current track with transcoding
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                ["status", "-", "1", "tags:u"]  // Get current track URL with transcoding
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
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: self.logger, "JSON-RPC request failed: %{public}s", error.localizedDescription)
                return
            }
            
            guard let data = data else {
                os_log(.error, log: self.logger, "No data received from JSON-RPC")
                return
            }
            
            // Parse response to get transcoded URL
            self.parseTranscodedURLResponse(data: data)
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Requesting transcoded URL via JSON-RPC API")
    }
    
    private func parseTranscodedURLResponse(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let loop = result["playlist_loop"] as? [[String: Any]],
               let firstTrack = loop.first {
                
                os_log(.info, log: logger, "🔍 JSON-RPC response track info: %{public}s", String(describing: firstTrack))
                
                // *** PRIORITY: Use track ID with your working download format ***
                if let trackID = firstTrack["id"] as? Int {
                    let streamingURL = "http://\(host):9000/music/\(trackID)/download.mp3?bitrate=320"
                    os_log(.info, log: logger, "🎵 Using working download format with track ID: %{public}s", streamingURL)
                    
                    // Start playback with the working URL format
                    DispatchQueue.main.async {
                        self.audioManager.playStream(urlString: streamingURL)
                    }
                    return
                }
                
                // *** FALLBACK: Try other approaches if no ID ***
                var trackURL: String?
                
                if let url = firstTrack["url"] as? String {
                    trackURL = url
                } else if let path = firstTrack["path"] as? String {
                    let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
                    trackURL = "http://\(host):9000/music/\(encodedPath)?t=mp3&br=320000"
                }
                
                guard var finalURL = trackURL else {
                    os_log(.error, log: logger, "❌ Could not extract any URL from JSON response")
                    return
                }
                
                // Convert file:// URLs to HTTP streaming URLs
                if finalURL.starts(with: "file://") {
                    let filePath = finalURL.replacingOccurrences(of: "file://", with: "")
                    let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
                    finalURL = "http://\(host):9000/stream.mp3?path=\(encodedPath)&t=mp3&br=320000"
                    os_log(.info, log: logger, "🔄 Converted file URL to streaming URL: %{public}s", finalURL)
                }
                
                // Ensure transcoding parameters are present
                if !finalURL.contains("t=mp3") {
                    finalURL += finalURL.contains("?") ? "&t=mp3&br=320000" : "?t=mp3&br=320000"
                }
                
                os_log(.info, log: logger, "🎵 Final fallback URL: %{public}s", finalURL)
                
                // Start playback with the transcoded URL
                DispatchQueue.main.async {
                    self.audioManager.playStream(urlString: finalURL)
                }
            } else {
                os_log(.error, log: logger, "❌ Failed to parse JSON-RPC response")
                // Log the raw response for debugging
                if let responseString = String(data: data, encoding: .utf8) {
                    os_log(.debug, log: logger, "Raw JSON response: %{public}s", responseString)
                }
            }
        } catch {
            os_log(.error, log: logger, "JSON parsing error: %{public}s", error.localizedDescription)
        }
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
        
        // Get real-time info from audio manager if available
        let currentTime = getCurrentPlaybackTime()
        
        // Create a minimal but correct STAT message
        var statusData = Data()
        
        // Event Code (4 bytes) - like "STMt", "STMp", etc.
        let eventCode = code.padding(toLength: 4, withPad: " ", startingAt: 0)
        statusData.append(eventCode.data(using: .ascii) ?? Data())
        
        // Number of consecutive CRLF (1 byte)
        statusData.append(0)
        
        // MAS Initialized (1 byte) - 'm' for initialized
        statusData.append(UInt8(ascii: "m"))
        
        // MAS Mode (1 byte)
        statusData.append(0)
        
        // Buffer size (4 bytes) - fake reasonable value
        let bufferSize: UInt32 = 262144  // 256KB
        statusData.append(Data([
            UInt8((bufferSize >> 24) & 0xff),
            UInt8((bufferSize >> 16) & 0xff),
            UInt8((bufferSize >> 8) & 0xff),
            UInt8(bufferSize & 0xff)
        ]))
        
        // Buffer fullness (4 bytes) - fake reasonable value
        let bufferFullness: UInt32 = 131072  // 128KB
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
        
        // Output buffer fullness (4 bytes)
        let outputBufferFullness: UInt32 = 4096
        statusData.append(Data([
            UInt8((outputBufferFullness >> 24) & 0xff),
            UInt8((outputBufferFullness >> 16) & 0xff),
            UInt8((outputBufferFullness >> 8) & 0xff),
            UInt8(outputBufferFullness & 0xff)
        ]))
        
        // *** CRITICAL: Only set elapsed time for STMt status messages ***
        if code == "STMt" {
            // Elapsed seconds (4 bytes) - ONLY for status updates
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
            
            os_log(.info, log: logger, "STAT sent with elapsed time: %.2f seconds (raw: %d ms)", safeCurrentTime, elapsedMs)
        } else {
            // For non-status messages, don't include timing fields
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
