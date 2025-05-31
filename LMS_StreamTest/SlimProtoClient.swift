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
    
    init(audioManager: AudioManager = AudioManager()) {
        self.audioManager = audioManager
        super.init()
        os_log(.info, log: logger, "SlimProtoClient initializing")
        socket = GCDAsyncSocket(delegate: self, delegateQueue: DispatchQueue(label: "com.lmsstream.socket"))
        os_log(.info, log: logger, "Socket initialized with custom queue")
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
        // Be very explicit about supported formats and add device info
        let capabilities = "mp3,aac,pcm,Model=squeezeslave,ModelName=LMSStream,MaxSampleRate=48000,HasDigitalOut,HasPreAmp"
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
                                audioManager.playStream(urlString: url)
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
                    // For status requests, extract the server timestamp from the payload
                    if streamCommand == UInt8(ascii: "t") && payload.count >= 24 {
                        // Extract server timestamp from replay_gain field (bytes 16-19)
                        let timestampData = payload.subdata(in: 16..<20)
                        serverTimestamp = timestampData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                        os_log(.debug, log: logger, "Extracted server timestamp: %d", serverTimestamp)
                    }
                    
                    switch streamCommand {
                    case UInt8(ascii: "p"): // pause
                        audioManager.pause()
                        sendStatus("STMp")
                    case UInt8(ascii: "u"): // unpause
                        audioManager.play()
                        sendStatus("STMr")
                    case UInt8(ascii: "q"): // stop
                        audioManager.stop()
                        sendStatus("STMf")
                    case UInt8(ascii: "t"): // status request
                        sendStatus("STMt") // Just send timer/heartbeat status
                    case UInt8(ascii: "f"): // flush
                        audioManager.stop()
                        sendStatus("STMf")
                    default:
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
    
    private func extractURLFromHTTPRequest(_ httpRequest: String) -> String? {
        // Parse HTTP request like "GET /stream.mp3?player=xx:xx:xx:xx:xx:xx HTTP/1.0"
        let lines = httpRequest.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        
        let path = parts[1]
        
        // Use the original stream URL - VLC can handle FLAC
        let fullURL = "http://\(host):9000\(path)"
        return fullURL
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
        let bytesReceived: UInt64 = UInt64(currentTime * Double(estimatedBitrate) / 8.0)
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
            let elapsedSeconds = UInt32(currentTime)
            statusData.append(Data([
                UInt8((elapsedSeconds >> 24) & 0xff),
                UInt8((elapsedSeconds >> 16) & 0xff),
                UInt8((elapsedSeconds >> 8) & 0xff),
                UInt8(elapsedSeconds & 0xff)
            ]))
            
            // Voltage (2 bytes)
            statusData.append(Data([0x00, 0x00]))
            
            // Elapsed milliseconds (4 bytes)
            let elapsedMs = UInt32(currentTime * 1000)
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
            
            os_log(.info, log: logger, "STAT sent with elapsed time: %.2f seconds (raw: %d ms)", currentTime, elapsedMs)
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
        
        // Add some bounds checking to prevent crazy values
        if currentTime < 0 || currentTime > 86400 { // Max 24 hours
            return 0.0
        }
        
        return currentTime
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
        
        // Attempt to reconnect after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.connect()
        }
    }
}
