// File: SlimProtoClient.swift
// Fixed to properly identify as LyrPlay app instead of AppleCoreMedia
import Foundation
import AVFoundation
import CocoaAsyncSocket
import os.log

// MARK: - Protocol Delegates
protocol SlimProtoClientDelegate: AnyObject {
    func slimProtoDidConnect()
    func slimProtoDidDisconnect(error: Error?)
    func slimProtoDidReceiveCommand(_ command: SlimProtoCommand)
}

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

// MARK: - Framing
/// Decision logic for the 2-byte length-prefixed SlimProto server stream,
/// extracted as a pure function so the invalid-length path is unit-testable.
enum SlimProtoFraming {
    /// Sanity cap — real server frames are far smaller. An over-cap frame is
    /// treated as garbage, but its payload must still be consumed to keep the
    /// TCP stream aligned on frame boundaries.
    static let maxMessageLength: UInt16 = 10000

    enum HeaderAction: Equatable {
        case readMessage(length: UInt16)    // valid frame — read its payload
        case discardPayload(length: UInt16) // over-cap frame — consume and drop payload
        case readNextHeader                 // zero-length frame — nothing to consume
    }

    static func action(forHeader data: Data) -> HeaderAction {
        guard data.count >= 2 else { return .readNextHeader }
        let length = data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        if length == 0 { return .readNextHeader }
        return length < maxMessageLength
            ? .readMessage(length: length)
            : .discardPayload(length: length)
    }
}

// MARK: - Core Protocol Handler
class SlimProtoClient: NSObject, GCDAsyncSocketDelegate {
    
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
    private var isPaused: Bool = false
    private var isStreamActive: Bool = false
    
    // MARK: - Delegation
    weak var delegate: SlimProtoClientDelegate?
    
    weak var commandHandler: SlimProtoCommandHandler?
    
    // MARK: - Initialization
    override init() {
        super.init()
        loadSettings()
        setupSocket()
        #if DEBUG
        os_log(.info, log: logger, "SlimProtoClient initialized - Host: %{public}s:%d", host, port)
        #endif
    }
    
    // MARK: - Settings Integration
    private func loadSettings() {
        host = settings.activeServerHost
        port = UInt16(settings.activeServerSlimProtoPort)
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
        #if DEBUG
        os_log(.info, log: logger, "Socket initialized")
        #endif
    }
    
    // MARK: - Connection Management
    func connect() {
        guard !host.isEmpty else {
            os_log(.error, log: logger, "Cannot connect - host is empty")
            return
        }
        
        // CRITICAL FIX: Clean up any existing connection first
        if isConnected || socket.isConnected {
            os_log(.info, log: logger, "Cleaning up existing connection before reconnecting")
            disconnect()
            
            // Wait a moment for cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.attemptConnection()
            }
        } else {
            attemptConnection()
        }
    }
    
    private func attemptConnection() {
        guard !isConnected else {
            os_log(.info, log: logger, "Already connected")
            return
        }
        
        // Refresh settings before connecting
        loadSettings()
        
        os_log(.info, log: logger, "Attempting to connect to %{public}s:%d", host, port)
        
        do {
            // 4s TCP connect timeout enables fast failover to backup server (issue #76)
            try socket.connect(toHost: host, onPort: port, withTimeout: 4)
        } catch {
            os_log(.error, log: logger, "Connection error: %{public}s", error.localizedDescription)
        }
    }
    
    func disconnect() {
        if socket.isConnected {
            socket.disconnect()
        }
        isConnected = false
        hasRequestedInitialStatus = false
        os_log(.info, log: logger, "Disconnected and reset connection state")
    }
    
    func disconnectWithPositionSave() {
        if socket.isConnected {
            // Send SHUT command to trigger server's persistPlaybackStateForPowerOff()
            sendShutCommand()
            
            // Give server a moment to process SHUT, then disconnect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.socket.disconnect()
            }
        }
        isConnected = false
        hasRequestedInitialStatus = false
        os_log(.info, log: logger, "Sent SHUT command and disconnected to trigger server position saving")
    }
    
    private func sendShutCommand() {
        let command = "SHUT"
        let length = UInt32(0) // No additional data
        
        var frame = Data()
        frame.append(command.data(using: .ascii)!)
        frame.append(withUnsafeBytes(of: length.bigEndian) { Data($0) })
        
        socket.write(frame, withTimeout: 1.0, tag: 0)
        os_log(.info, log: logger, "🔌 Sent SHUT command to trigger server position saving")
    }
    
    // MARK: - Socket Delegate Methods
    // NOTE (single-threaded control plane, bd LMS_StreamTest-433.2.1):
    // GCDAsyncSocket delivers these callbacks on the socket queue. Socket I/O
    // (HELO send, read re-arm, framing) stays here, but connection state and
    // every delegate notification hop to MAIN — the whole control plane
    // (coordinator, command handler, timers) is main-thread-confined,
    // matching squeezelite's single-threaded slimproto loop.
    func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        os_log(.info, log: logger, "✅ Connected to LMS at %{public}s:%d", host, port)

        // Send HELO and arm the first header read immediately — the server
        // replies to HELO right away.
        sendHelo()
        socket.readData(toLength: 2, withTimeout: 30, tag: 0)
        os_log(.info, log: logger, "Read data initiated after connect - expecting 2-byte length header")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = true

            // Request initial status after brief delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !self.hasRequestedInitialStatus {
                    self.hasRequestedInitialStatus = true
                    self.sendStatus("STMt")
                    os_log(.info, log: self.logger, "🔄 Requested initial status to detect existing streams")
                }
            }

            self.delegate?.slimProtoDidConnect()
        }
    }

    func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        if let error = err {
            os_log(.error, log: logger, "❌ Disconnected with error: %{public}s", error.localizedDescription)
        } else {
            os_log(.info, log: logger, "🔌 Disconnected gracefully")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
            self.hasRequestedInitialStatus = false
            self.delegate?.slimProtoDidDisconnect(error: err)
        }
    }
    
    func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        if tag == 0 {
            // Read 2-byte length header
            guard data.count >= 2 else {
                os_log(.error, log: logger, "Length header too short: %d bytes", data.count)
                socket.readData(toLength: 2, withTimeout: 30, tag: 0)
                return
            }
            
            // Too spammy - uncomment only for debugging message parsing
            // os_log(.debug, log: logger, "Server message length: %d bytes", messageLength)

            switch SlimProtoFraming.action(forHeader: data) {
            case .readMessage(let length):
                socket.readData(toLength: UInt(length), withTimeout: 30, tag: 1)
            case .discardPayload(let length):
                // The oversized frame's payload is still in the TCP stream —
                // it must be consumed before the next header read, or every
                // subsequent "header" is actually message body (permanent desync).
                os_log(.error, log: logger, "Invalid message length: %d — discarding payload to stay frame-aligned", length)
                socket.readData(toLength: UInt(length), withTimeout: 30, tag: 2)
            case .readNextHeader:
                os_log(.error, log: logger, "Zero message length")
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

            // Too spammy - uncomment only for debugging server commands
            // os_log(.debug, log: logger, "📨 Received: %{public}s (%d bytes)", commandString, payloadData.count)

            // Command processing runs on main (single-threaded control plane).
            // Main-queue FIFO preserves server command order.
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.slimProtoDidReceiveCommand(command)
            }

            // Continue reading
            socket.readData(toLength: 2, withTimeout: 30, tag: 0)

        } else if tag == 2 {
            // Discarded payload of an invalid-length frame — stream is
            // frame-aligned again, resume header reads.
            socket.readData(toLength: 2, withTimeout: 30, tag: 0)
        }
    }
    
    // MARK: - FIXED: Protocol Messages with proper device identification
    private func sendHelo() {
        os_log(.info, log: logger, "Sending HELO message as LyrPlay for iOS")

        // *** CRITICAL FIX: Use correct device ID for iOS app identification ***
        // Use device ID 9 (squeezelite) which is better recognized by LMS
        // This prevents the "AppleCoreMedia" identification issue
        let deviceID: UInt8 = 12   // squeezelite - well-supported by LMS
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

        // WLAN channel list (2 bytes) - always 0x0000
        // Client-side playlist jump recovery handles position restoration
        let wlanChannels: UInt16 = 0x0000
        helloData.append(Data([UInt8(wlanChannels >> 8), UInt8(wlanChannels & 0xff)]))

        // Bytes received (8 bytes) - optional, starting at 0
        helloData.append(Data(repeating: 0, count: 8))

        // Language (2 bytes) - optional, "en"
        helloData.append("en".data(using: .ascii) ?? Data([0x65, 0x6e]))

        // *** FIXED: Enhanced capabilities string with user-configurable FLAC support ***
        var capabilities = settings.capabilitiesString

        // Rejoin sync group across reconnects: the server regex-matches the TEXT
        // "SyncgroupID=\d{10}" INSIDE the capabilities string (Slimproto.pm:985),
        // and squeezelite appends ",SyncgroupID=<digits>" (slimproto.c:480). The
        // old form — NUL + 10 raw bytes after the string — could never match.
        // bd LMS_StreamTest-433.4.2
        if let savedSyncGroup = settings.loadSyncGroupID() {
            capabilities += ",SyncgroupID=\(savedSyncGroup)"
            os_log(.info, log: logger, "🔗 Including saved sync group ID in HELO: %{public}s", savedSyncGroup)
        }

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
    
    /// System uptime in milliseconds as SlimProto jiffies, wrapping at
    /// UInt32.max (~49.7 days of uptime) like squeezelite's gettime_ms.
    /// A plain UInt32(Double) conversion traps past that uptime, crashing the
    /// app on every STAT send until the phone is rebooted (bd LMS_StreamTest-7a8).
    static func jiffies(uptimeSeconds: TimeInterval) -> UInt32 {
        return UInt32(truncatingIfNeeded: Int64(uptimeSeconds * 1000))
    }

    func sendStatus(_ code: String, serverTimestamp: UInt32 = 0) {
        guard isConnected else {
            os_log(.error, log: logger, "Cannot send status - not connected")
            return
        }

        // Too spammy - uncomment only for debugging STAT sends
        // os_log(.debug, log: logger, "Sending STAT: %{public}s", code)

        var statusData = Data()
        
        // Event code (4 bytes, space-padded)
        let eventCode = code.padding(toLength: 4, withPad: " ", startingAt: 0)
        statusData.append(eventCode.data(using: .ascii) ?? Data())
        
        // Basic fields (same for ALL status packets)
        statusData.append(0) // num_crlf
        statusData.append(UInt8(ascii: "m")) // MAS Initialized
        
        // MAS Mode based on code
        if code == "STMp" {
            statusData.append(UInt8(ascii: "p")) // Paused
        } else {
            statusData.append(0) // Playing/other
        }
        
        // Real buffer/byte telemetry from the active stream path — the old code
        // fabricated all three (fullness = size/2, bytesReceived = wall clock ×
        // 40000). LMS uses them for rebuffer detection and display; squeezelite
        // reports real values. bd LMS_StreamTest-433.4.3
        let telemetry = commandHandler?.getStatTelemetry() ?? SlimProtoStatTelemetry()

        // Buffer info (8 bytes total)
        // Network buffer size in bytes (not playback buffer duration)
        let bufferSize = UInt32(settings.networkBufferKB * 1024)
        statusData.append(Data([
            UInt8((bufferSize >> 24) & 0xff),
            UInt8((bufferSize >> 16) & 0xff),
            UInt8((bufferSize >> 8) & 0xff),
            UInt8(bufferSize & 0xff)
        ]))

        // Rcv buffer fullness: bytes downloaded but not yet decoded, clamped to
        // the reported capacity.
        let bufferFullness = UInt32(min(telemetry.streamBufferedBytes, UInt64(bufferSize)))
        statusData.append(Data([
            UInt8((bufferFullness >> 24) & 0xff),
            UInt8((bufferFullness >> 16) & 0xff),
            UInt8((bufferFullness >> 8) & 0xff),
            UInt8(bufferFullness & 0xff)
        ]))

        // Bytes received (8 bytes total): downloaded since the current stream
        // started (squeezelite's per-stream counter, reset by each strm 's').
        let bytesReceived = telemetry.bytesReceived
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
        
        // Signal strength (2 bytes)
        statusData.append(Data([0xFF, 0xFF])) // Like C reference: 0xffff
        
        // Jiffies (4 bytes) - CRITICAL: Must use system uptime, NOT Unix epoch time
        // Server calculates player's jiffies epoch based on this value
        // Using wrong time source causes synchronized start to target far future
        // squeezelite: gettime_ms() = system uptime in milliseconds
        let jiffies = SlimProtoClient.jiffies(uptimeSeconds: ProcessInfo.processInfo.systemUptime)
        statusData.append(Data([
            UInt8((jiffies >> 24) & 0xff),
            UInt8((jiffies >> 16) & 0xff),
            UInt8((jiffies >> 8) & 0xff),
            UInt8(jiffies & 0xff)
        ]))
        
        // Output buffer size (4 bytes): decoded-PCM capacity (decode loop's
        // soft-throttle ceiling on the push path). Floor at the old constant so
        // an idle player never reports a zero-size buffer (server-side ratios).
        let outputBufferSize = max(UInt32(clamping: telemetry.outputBufferCapacity), 8192)
        statusData.append(Data([
            UInt8((outputBufferSize >> 24) & 0xff),
            UInt8((outputBufferSize >> 16) & 0xff),
            UInt8((outputBufferSize >> 8) & 0xff),
            UInt8(outputBufferSize & 0xff)
        ]))

        // Output buffer fullness (4 bytes): decoded PCM awaiting playback
        // (push-stream queue + BASS playback buffer), clamped to capacity.
        let outputBufferFullness = UInt32(min(telemetry.outputBufferedBytes, UInt64(outputBufferSize)))
        statusData.append(Data([
            UInt8((outputBufferFullness >> 24) & 0xff),
            UInt8((outputBufferFullness >> 16) & 0xff),
            UInt8((outputBufferFullness >> 8) & 0xff),
            UInt8(outputBufferFullness & 0xff)
        ]))
        
        // CRITICAL: Always include ALL remaining fields for consistent packet structure

        // Get current audio position for timing.
        // Subtract iOS output latency (AVAudioSession.outputLatency = iOS Audio Queue +
        // hardware latency, ~15ms typical, equivalent to squeezelite's device_frames /
        // sample_rate). Without this, BASS_ChannelGetPosition reports samples consumed
        // by the BASS mixer — the iOS HAL ring buffer that sits between BASS and the
        // speaker is invisible, so STAT elapsed_ms is consistently ahead of where
        // audio has actually been heard. Fixes Bug 4 in the sync drift plan.
        let position: Double
        if let commandHandler = commandHandler {
            position = commandHandler.getCurrentAudioTime()
        } else {
            position = 0.0
        }
        let outputLatency = AVAudioSession.sharedInstance().outputLatency
        let adjusted = max(0, position - outputLatency)
        let clampedPosition = min(adjusted, 86400) // Max 24 hours
        
        // NOTE: Don't update coordinator with audio player time - that's wrong!
        // The coordinator should get server time from JSON-RPC responses, not audio player time
        // coordinator.updateServerTime(position: clampedPosition, isPlaying: isPlaying)
        
        // Elapsed seconds (4 bytes)
        let elapsedSeconds = UInt32(clampedPosition)
        statusData.append(Data([
            UInt8((elapsedSeconds >> 24) & 0xff),
            UInt8((elapsedSeconds >> 16) & 0xff),
            UInt8((elapsedSeconds >> 8) & 0xff),
            UInt8(elapsedSeconds & 0xff)
        ]))
        
        // Voltage (2 bytes) - not used
        statusData.append(Data([0x00, 0x00]))
        
        // Elapsed milliseconds (4 bytes)
        let elapsedMs = UInt32(clampedPosition * 1000)
        statusData.append(Data([
            UInt8((elapsedMs >> 24) & 0xff),
            UInt8((elapsedMs >> 16) & 0xff),
            UInt8((elapsedMs >> 8) & 0xff),
            UInt8(elapsedMs & 0xff)
        ]))
        
        // Server timestamp (4 bytes) - echo back what server sent us
        statusData.append(Data([
            UInt8((serverTimestamp >> 24) & 0xff),
            UInt8((serverTimestamp >> 16) & 0xff),
            UInt8((serverTimestamp >> 8) & 0xff),
            UInt8(serverTimestamp & 0xff)
        ]))
        
        // Error code (2 bytes)
        statusData.append(Data([0x00, 0x00]))
        
        // Create and send the message
        let command = "STAT".data(using: .ascii)!
        let length = UInt32(statusData.count).bigEndian
        let lengthData = withUnsafeBytes(of: length) { Data($0) }
        
        var fullMessage = Data()
        fullMessage.append(command)
        fullMessage.append(lengthData)
        fullMessage.append(statusData)

        // Too spammy - uncomment only for debugging STAT packets
        // os_log(.debug, log: logger, "STAT packet: %{public}s", fullMessage.map { String(format: "%02X", $0) }.joined(separator: " "))

        socket.write(fullMessage, withTimeout: 30, tag: 2)
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
