// File: SlimProtoClient.swift
// Fixed to properly identify as LMS Stream app instead of AppleCoreMedia
import Foundation
import CocoaAsyncSocket
import os.log

// MARK: - Protocol Delegates
protocol SlimProtoClientDelegate: AnyObject {
    func slimProtoDidConnect()
    func slimProtoDidDisconnect(error: Error?)
    func slimProtoDidReceiveCommand(_ command: SlimProtoCommand)
}

// MARK: - Command Deduplication (ADD THESE LINES)
private var lastSentCommand: String = ""
private var lastSentTime: Date = Date()
private let minimumCommandInterval: TimeInterval = 0.2  // 200ms minimum between commands

// MARK: - Command Structure
struct SlimProtoCommand {
    let type: String
    let payload: Data
    
    // Stream command details
    var streamCommand: UInt8? {
        guard type == "strm", payload.count >= 1 else { return nil }
        return payload[0]
    }
    
    var streamFormat: UInt8? {
        guard type == "strm", payload.count >= 3 else { return nil }
        return payload[2]
    }
    
    var httpRequest: String? {
        guard type == "strm", payload.count > 24 else { return nil }
        let httpData = payload.subdata(in: 24..<payload.count)
        return String(data: httpData, encoding: .utf8)
    }
}

// MARK: - Core Protocol Handler
class SlimProtoClient: NSObject, GCDAsyncSocketDelegate, ObservableObject {
    
    // MARK: - Dependencies
    private let settings = SettingsManager.shared
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoCore")
    
    // MARK: - Socket Management
    private var socket: GCDAsyncSocket!
    private var isConnected = false
    
    // MARK: - Connection State
    private var host: String = ""
    private var port: UInt16 = 3483
    private var hasRequestedInitialStatus = false
    
    // MARK: - Time Reporting State
    private var serverTimestamp: UInt32 = 0
    private var playbackStartTime: Date?
    private var pausedPosition: Double = 0.0
    private var isPaused: Bool = false
    private var isStreamActive: Bool = false
    private var lastKnownPosition: Double = 0.0
    
    private var lastSuccessfulConnection: Date?
    
    // MARK: - Delegation
    weak var delegate: SlimProtoClientDelegate?
    
    weak var commandHandler: SlimProtoCommandHandler?
    
    // MARK: - Initialization
    override init() {
        super.init()
        loadSettings()
        setupSocket()
        os_log(.info, log: logger, "SlimProtoClient initialized - Host: %{public}s:%d", host, port)
    }
    
    // MARK: - Settings Integration
    private func loadSettings() {
        host = settings.serverHost
        port = UInt16(settings.serverSlimProtoPort)
        os_log(.info, log: logger, "Settings loaded - Host: %{public}s, Port: %d", host, port)
    }
    
    func updateServerSettings(host: String, port: UInt16) {
        self.host = host
        self.port = port
        os_log(.info, log: logger, "Server settings updated - Host: %{public}s, Port: %d", host, port)
    }
    
    // MARK: - Socket Setup
    private func setupSocket() {
        socket = GCDAsyncSocket(delegate: self, delegateQueue: DispatchQueue(label: "com.lmsstream.socket"))
        os_log(.info, log: logger, "Socket initialized")
    }
    
    // MARK: - Connection Management
    func connect() {
        guard !host.isEmpty else {
            os_log(.error, log: logger, "Cannot connect - host is empty")
            return
        }
        
        guard !isConnected else {
            os_log(.info, log: logger, "Already connected")
            return
        }
        
        // Refresh settings before connecting
        loadSettings()
        
        os_log(.info, log: logger, "Attempting to connect to %{public}s:%d", host, port)
        
        do {
            try socket.connect(toHost: host, onPort: port, withTimeout: 30)
        } catch {
            os_log(.error, log: logger, "Connection error: %{public}s", error.localizedDescription)
        }
    }
    
    func disconnect() {
        socket.disconnect()
        isConnected = false
        hasRequestedInitialStatus = false
        os_log(.info, log: logger, "Disconnected")
    }
    
    // MARK: - Socket Delegate Methods
    func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        lastSuccessfulConnection = Date()  // ADD THIS LINE
        isConnected = true
        os_log(.info, log: logger, "✅ Connected to LMS at %{public}s:%d", host, port)
        
        // Send HELO message
        sendHelo()
        
        // Start reading server messages - they start with 2-byte length
        socket.readData(toLength: 2, withTimeout: 30, tag: 0)
        os_log(.info, log: logger, "Read data initiated after connect - expecting 2-byte length header")
        
        // Request initial status after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !self.hasRequestedInitialStatus {
                self.hasRequestedInitialStatus = true
                self.sendStatus("STMt")
                os_log(.info, log: self.logger, "🔄 Requested initial status to detect existing streams")
            }
        }
        
        // Notify delegate
        delegate?.slimProtoDidConnect()
    }
    
    func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        isConnected = false
        hasRequestedInitialStatus = false
        
        if let error = err {
            os_log(.error, log: logger, "❌ Disconnected with error: %{public}s", error.localizedDescription)
        } else {
            os_log(.info, log: logger, "🔌 Disconnected gracefully")
        }
        
        // Notify delegate
        delegate?.slimProtoDidDisconnect(error: err)
    }
    
    func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        if tag == 0 {
            // Read 2-byte length header
            guard data.count >= 2 else {
                os_log(.error, log: logger, "Length header too short: %d bytes", data.count)
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
                return
            }
            
            // Parse 2-byte length in network order
            let messageLength = data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            os_log(.info, log: logger, "Server message length: %d bytes", messageLength)
            
            if messageLength > 0 && messageLength < 10000 {
                socket.readData(toLength: UInt(messageLength), withTimeout: 30, tag: 1)
            } else {
                os_log(.error, log: logger, "Invalid message length: %d", messageLength)
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
            }
            
        } else if tag == 1 {
            // Read complete message
            guard data.count >= 4 else {
                os_log(.error, log: logger, "Message too short: %d bytes", data.count)
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
                return
            }
            
            let commandData = data.subdata(in: 0..<4)
            let payloadData = data.count > 4 ? data.subdata(in: 4..<data.count) : Data()
            
            guard let commandString = String(data: commandData, encoding: .ascii) else {
                os_log(.error, log: logger, "Failed to decode command")
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
                return
            }
            
            // Create command structure
            let command = SlimProtoCommand(type: commandString, payload: payloadData)
            
            os_log(.info, log: logger, "📨 Received: %{public}s (%d bytes)", commandString, payloadData.count)
            
            // Notify delegate
            delegate?.slimProtoDidReceiveCommand(command)
            
            // Continue reading
            socket.readData(toLength: 2, withTimeout: 30, tag: 0)
        }
    }
    
    // MARK: - FIXED: Protocol Messages with proper device identification
    private func sendHelo() {
        os_log(.info, log: logger, "Sending HELO message as LMS Stream for iOS")
        
        // *** CRITICAL FIX: Use correct device ID for iOS app identification ***
        // Use device ID 9 (squeezelite) which is better recognized by LMS
        // This prevents the "AppleCoreMedia" identification issue
        let deviceID: UInt8 = 9   // squeezelite - well-supported by LMS
        let revision: UInt8 = 0   // Standard revision
        
        // Get MAC address from settings
        let macString = settings.playerMACAddress
        let macComponents = macString.components(separatedBy: ":")
        let macAddress: [UInt8] = macComponents.compactMap { UInt8($0, radix: 16) }
        let finalMacAddress: [UInt8] = macAddress.count == 6 ? macAddress : [0x00, 0x04, 0x20, 0x12, 0x34, 0x56]
        
        var helloData = Data()
        
        // Device ID (1 byte) - 9 = squeezelite for better LMS compatibility
        helloData.append(deviceID)
        
        // Revision (1 byte)
        helloData.append(revision)
        
        // MAC address (6 bytes)
        helloData.append(Data(finalMacAddress))
        
        // UUID (16 bytes) - optional, using zeros
        helloData.append(Data(repeating: 0, count: 16))
        
        // WLan channel list (2 bytes) - 0x0000 for wired connection
        let wlanChannels: UInt16 = 0x0000  // Wired connection like real squeezelite
        helloData.append(Data([UInt8(wlanChannels >> 8), UInt8(wlanChannels & 0xff)]))
        
        // Bytes received (8 bytes) - optional, starting at 0
        helloData.append(Data(repeating: 0, count: 8))
        
        // Language (2 bytes) - optional, "en"
        helloData.append("en".data(using: .ascii) ?? Data([0x65, 0x6e]))
        
        // *** FIXED: Enhanced capabilities string with proper player identification ***
        let capabilities = settings.capabilitiesString
        if let capabilitiesData = capabilities.data(using: .utf8) {
            helloData.append(capabilitiesData)
            os_log(.info, log: logger, "Added capabilities: %{public}s", capabilities)
        }
        
        // Create full message
        let command = "HELO".data(using: .ascii)!
        let length = UInt32(helloData.count).bigEndian
        let lengthData = withUnsafeBytes(of: length) { Data($0) }
        
        var fullMessage = Data()
        fullMessage.append(command)
        fullMessage.append(lengthData)
        fullMessage.append(helloData)
        
        socket.write(fullMessage, withTimeout: 30, tag: 1)
        os_log(.info, log: logger, "✅ HELO sent as squeezelite with player name: '%{public}s', MAC: %{public}s",
               settings.effectivePlayerName, settings.formattedMACAddress)
    }
    
    func sendStatus(_ code: String) {
        guard isConnected else {
            os_log(.error, log: logger, "Cannot send status - not connected")
            return
        }
        
        // CRITICAL: Prevent command spam
        let now = Date()
        let timeSinceLastCommand = now.timeIntervalSince(lastSentTime)
        
        // Check for duplicate commands sent too quickly
        if lastSentCommand == code && timeSinceLastCommand < minimumCommandInterval {
            os_log(.error, log: logger, "🚫 Blocked duplicate command: %{public}s (%.3fs since last)",
                   code, timeSinceLastCommand)
            return
        }
        
        // Update tracking
        lastSentCommand = code
        lastSentTime = now
        
        os_log(.info, log: logger, "📤 Sending STAT: %{public}s", code)
        
        // Create status message
        var statusData = Data()
        
        // Event Code (4 bytes)
        let eventCode = code.padding(toLength: 4, withPad: " ", startingAt: 0)
        statusData.append(eventCode.data(using: .ascii) ?? Data())
        
        // Number of consecutive CRLF (1 byte)
        statusData.append(0)
        
        // MAS Initialized (1 byte)
        statusData.append(UInt8(ascii: "m"))
        
        // MAS Mode (1 byte) - reflect actual pause state
        if isPaused || code == "STMp" {
            statusData.append(UInt8(ascii: "p")) // 'p' = paused
            os_log(.info, log: logger, "🔒 MAS Mode set to PAUSED ('p')")
        } else {
            statusData.append(0) // 0 = playing/stopped
            os_log(.info, log: logger, "▶️ MAS Mode set to PLAYING (0)")
        }
        
        // Buffer size (4 bytes) - from settings
        let bufferSize = UInt32(settings.bufferSize)
        statusData.append(Data([
            UInt8((bufferSize >> 24) & 0xff),
            UInt8((bufferSize >> 16) & 0xff),
            UInt8((bufferSize >> 8) & 0xff),
            UInt8(bufferSize & 0xff)
        ]))
        
        // Buffer fullness (4 bytes) - when paused, show buffer as empty/minimal
        let bufferFullness: UInt32 = isPaused ? 0 : bufferSize / 2
        statusData.append(Data([
            UInt8((bufferFullness >> 24) & 0xff),
            UInt8((bufferFullness >> 16) & 0xff),
            UInt8((bufferFullness >> 8) & 0xff),
            UInt8(bufferFullness & 0xff)
        ]))
        
        // Bytes received (8 bytes) - SIMPLIFIED: Use basic estimation without position calculations
        let estimatedBitrate: UInt64 = 320000 // 320kbps default
        let connectionTimeSeconds = lastSuccessfulConnection?.timeIntervalSinceNow ?? 0
        let connectionDuration = abs(connectionTimeSeconds)
        let bytesReceived: UInt64 = UInt64(connectionDuration * Double(estimatedBitrate) / 8.0)
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
        
        // Signal strength (2 bytes) - 0x0000 = wired connection (like real squeezelite)
        statusData.append(Data([0x00, 0x00]))
        
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
        let outputBufferFullness: UInt32 = isPaused ? 0 : 4096
        statusData.append(Data([
            UInt8((outputBufferFullness >> 24) & 0xff),
            UInt8((outputBufferFullness >> 16) & 0xff),
            UInt8((outputBufferFullness >> 8) & 0xff),
            UInt8(outputBufferFullness & 0xff)
        ]))
        
        // *** PROTOCOL FIX: Include timing fields when server explicitly requests status ***
        if code == "STMt" || code == "STMp" {
            // When server requests status, provide actual position
            let actualPosition: Double
            if let commandHandler = commandHandler {
                actualPosition = commandHandler.getServerProvidedTime()
            } else {
                actualPosition = getCurrentPlaybackPosition()
            }
            
            // Clamp position to reasonable bounds
            let clampedPosition = max(0, min(actualPosition, 86400)) // Max 24 hours
            
            // Elapsed seconds (4 bytes) - ACTUAL position when server requests it
            let elapsedSeconds = UInt32(clampedPosition)
            statusData.append(Data([
                UInt8((elapsedSeconds >> 24) & 0xff),
                UInt8((elapsedSeconds >> 16) & 0xff),
                UInt8((elapsedSeconds >> 8) & 0xff),
                UInt8(elapsedSeconds & 0xff)
            ]))
            
            // Voltage (2 bytes)
            statusData.append(Data([0x00, 0x00]))
            
            // Elapsed milliseconds (4 bytes) - ACTUAL position in milliseconds
            let elapsedMs = UInt32(clampedPosition * 1000)
            statusData.append(Data([
                UInt8((elapsedMs >> 24) & 0xff),
                UInt8((elapsedMs >> 16) & 0xff),
                UInt8((elapsedMs >> 8) & 0xff),
                UInt8(elapsedMs & 0xff)
            ]))
            
            // Server timestamp (4 bytes) - ECHO BACK EXACTLY AS RECEIVED
            statusData.append(Data([
                UInt8((serverTimestamp >> 24) & 0xff),
                UInt8((serverTimestamp >> 16) & 0xff),
                UInt8((serverTimestamp >> 8) & 0xff),
                UInt8(serverTimestamp & 0xff)
            ]))
            
            // Error code (2 bytes)
            statusData.append(Data([0x00, 0x00]))
            
            os_log(.info, log: logger, "STAT sent - %{public}s with actual position %.2f (server requested)", code, clampedPosition)
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
    
    func sendSleepStatus() {
        guard isConnected else {
            os_log(.error, log: logger, "Cannot send sleep status - not connected")
            return
        }
        
        os_log(.info, log: logger, "💤 Sending proper PAUSE status before sleep")
        
        // Just send a standard pause status - don't invent new protocol codes
        sendStatus("STMp")
    }
    
    // MARK: - Playback State Management
    func setServerTimestamp(_ timestamp: UInt32) {
        serverTimestamp = timestamp
        os_log(.debug, log: logger, "Server timestamp set: %d", timestamp)
    }
    
    func setPlaybackState(isPlaying: Bool, position: Double) {
        os_log(.info, log: logger, "🔍 setPlaybackState called - isPlaying: %{public}s, position: %.2f, current isPaused: %{public}s",
               isPlaying ? "YES" : "NO", position, isPaused ? "YES" : "NO")
        
        if isPlaying && isPaused {
            // Resuming from pause
            playbackStartTime = Date().addingTimeInterval(-position)
            isPaused = false
            pausedPosition = 0.0
        } else if !isPlaying && !isPaused {
            // Pausing (was playing, now pausing) OR stopping
            pausedPosition = position
            isPaused = true
            lastKnownPosition = position
        } else if isPlaying && !isPaused {
            // Starting new track or continuing play
            playbackStartTime = Date().addingTimeInterval(-position)
            pausedPosition = 0.0
            isStreamActive = true
        } else if !isPlaying && isPaused {
            // Already paused, just updating the position
            lastKnownPosition = position
            pausedPosition = position
        }
        
        os_log(.debug, log: logger, "Playback state updated - Playing: %{public}s, Position: %.2f",
               isPlaying ? "YES" : "NO", position)
    }
    
    func getCurrentPlaybackPosition() -> Double {
        if isPaused {
            return pausedPosition
        } else if let startTime = playbackStartTime {
            return Date().timeIntervalSince(startTime)
        } else {
            return 0.0
        }
    }
    
    private func getCurrentPlaybackTime() -> Double {
        let currentTime = getCurrentPlaybackPosition()
        
        // Add bounds checking
        if currentTime < 0 || currentTime > 86400 { // Max 24 hours
            return 0.0
        }
        
        return currentTime
    }
    
    // MARK: - Public Interface
    var connectionState: String {
        return isConnected ? "Connected" : "Disconnected"
    }
    
    // MARK: - Raw Message Sending (for SETD responses)
    func sendRawMessage(_ message: Data) {
        guard isConnected else {
            os_log(.error, log: logger, "Cannot send raw message - not connected")
            return
        }
        
        socket.write(message, withTimeout: 30, tag: 3)
        os_log(.debug, log: logger, "📤 Raw message sent (%d bytes)", message.count)
    }
    
    deinit {
        disconnect()
    }
}
