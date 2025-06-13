// File: SlimProtoCommandHandler.swift
// UPDATED: Native FLAC support enabled with StreamingKit
import Foundation
import os.log

protocol SlimProtoCommandHandlerDelegate: AnyObject {
    func didStartStream(url: String, format: String, startTime: Double)
    func didPauseStream()
    func didResumeStream()
    func didStopStream()
    func didReceiveStatusRequest()
}

class SlimProtoCommandHandler: ObservableObject {
    
    // MARK: - Dependencies
    private let settings = SettingsManager.shared
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoCommands")
    
    // MARK: - State
    private var isStreamActive = false
    private var isPausedByLockScreen = false
    private var serverTimestamp: UInt32 = 0
    private var lastKnownPosition: Double = 0.0
    private var streamPosition: Double = 0.0
    private var streamDuration: Double = 0.0
    private var streamStartTime: Date?
    private var isStreamPaused: Bool = false
    private var lastStreamUpdate: Date = Date()
    private var serverStartTime: Date?
    private var serverStartPosition: Double = 0.0
    
    // MARK: - Delegation
    weak var delegate: SlimProtoCommandHandlerDelegate?
    weak var slimProtoClient: SlimProtoClient?
    
    // MARK: - Initialization
    init() {
        os_log(.info, log: logger, "SlimProtoCommandHandler initialized with FLAC support")
    }
    
    // MARK: - Command Processing (ENHANCED with SETD support)
    func processCommand(_ command: SlimProtoCommand) {
        switch command.type {
        case "strm":
            processServerCommand(command.type, payload: command.payload)
        case "setd":
            // Handle SETD commands for player name
            processSetdCommand(command.payload)
        case "audg", "aude":
            slimProtoClient?.sendStatus("STMt") // Acknowledge with heartbeat
        case "stat":
            // Respond to STAT requests based on actual state
            if isPausedByLockScreen {
                slimProtoClient?.sendStatus("STMp")
                os_log(.info, log: logger, "📍 STAT request - responding with PAUSE status")
            } else {
                slimProtoClient?.sendStatus("STMt")
            }
        case "vers":
            slimProtoClient?.sendStatus("STMt")
        case "vfdc":
            // Respond to VFD commands based on actual state
            if isPausedByLockScreen {
                slimProtoClient?.sendStatus("STMp")
            } else {
                slimProtoClient?.sendStatus("STMt")
            }
        case "grfe", "grfb":
            slimProtoClient?.sendStatus("STMt")
        default:
            os_log(.info, log: logger, "Unknown command: %{public}s", command.type)
            slimProtoClient?.sendStatus("STMt")
        }
    }
    
    func getCurrentStreamTime() -> Double {
        guard !isStreamPaused, let startTime = streamStartTime else {
            return streamPosition // Return frozen position when paused
        }
        
        // Calculate elapsed time since last update
        let elapsed = Date().timeIntervalSince(lastStreamUpdate)
        return streamPosition + elapsed
    }
    
    private func updateStreamPosition(_ position: Double) {
        streamPosition = position
        lastStreamUpdate = Date()
        streamStartTime = isStreamPaused ? nil : Date()
        
        os_log(.info, log: logger, "📍 Stream position updated: %.2f", position)
    }
    
    // MARK: - SETD Command Processing
    private func processSetdCommand(_ payload: Data) {
        guard payload.count >= 1 else {
            os_log(.error, log: logger, "SETD command payload too short")
            return
        }
        
        let setdId = payload[0]
        os_log(.info, log: logger, "📛 SETD command received - ID: %d, payload length: %d", setdId, payload.count)
        
        // Handle player name query and change (ID 0 = player name)
        if setdId == 0 {
            if payload.count == 1 {
                // Server is querying our player name - send it back
                os_log(.info, log: logger, "📛 Server requesting player name - sending: '%{public}s'", settings.effectivePlayerName)
                sendSetdPlayerName(settings.effectivePlayerName)
            } else if payload.count > 1 {
                // Server is setting our player name
                let nameData = payload.subdata(in: 1..<payload.count)
                if let newName = String(data: nameData, encoding: .utf8) {
                    let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    os_log(.info, log: logger, "📛 Server setting player name to: '%{public}s'", trimmedName)
                    
                    // Update our settings with the server-provided name
                    DispatchQueue.main.async {
                        self.settings.playerName = trimmedName
                        self.settings.saveSettings()
                    }
                    
                    // Confirm the change back to server
                    sendSetdPlayerName(trimmedName)
                } else {
                    os_log(.error, log: logger, "📛 Failed to decode SETD player name")
                }
            }
        } else {
            os_log(.info, log: logger, "📛 SETD command with unsupported ID: %d", setdId)
        }
    }
    
    // MARK: - Send SETD Player Name Response
    private func sendSetdPlayerName(_ playerName: String) {
        guard let slimProtoClient = slimProtoClient else {
            os_log(.error, log: logger, "Cannot send SETD - no client reference")
            return
        }
        
        // Create SETD response packet
        var setdData = Data()
        
        // SETD ID (1 byte) - 0 = player name
        setdData.append(0)
        
        // Player name as UTF-8 string
        if let nameData = playerName.data(using: .utf8) {
            setdData.append(nameData)
        }
        
        // Create the full message
        let command = "SETD".data(using: .ascii)!
        let length = UInt32(setdData.count).bigEndian
        let lengthData = withUnsafeBytes(of: length) { Data($0) }
        
        var fullMessage = Data()
        fullMessage.append(command)      // 4 bytes: "SETD"
        fullMessage.append(lengthData)   // 4 bytes: length
        fullMessage.append(setdData)     // payload: ID + name
        
        // Send via the client's socket
        slimProtoClient.sendRawMessage(fullMessage)
        
        os_log(.info, log: logger, "✅ SETD player name sent: '%{public}s' (%d bytes)", playerName, setdData.count)
    }
    
    // MARK: - Stream Command Processing (UPDATED for FLAC)
    private func processServerCommand(_ command: String, payload: Data) {
        guard command == "strm" else { return }
        
        if payload.count >= 24 {
            let streamCommand = payload[0]
            let autostart = payload[1]
            let format = payload[2]
            
            let commandChar = String(UnicodeScalar(streamCommand) ?? "?")
            os_log(.info, log: logger, "🎵 Server strm - command: '%{public}s' (%d), format: %d (0x%02x)",
                   commandChar, streamCommand, format, format)
            
            // UPDATED: Enhanced format handling with FLAC support
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
                
            case 102: // 'f' = FLAC - UPDATED: Now accept native FLAC
                formatName = "FLAC"
                shouldAccept = true // CHANGED: Now accept native FLAC
                os_log(.info, log: logger, "✅ Server offering FLAC - native playback with StreamingKit!")
                
            case 112: // 'p' = PCM
                formatName = "PCM"
                shouldAccept = true
                os_log(.info, log: logger, "✅ Server offering PCM - StreamingKit can handle this")
                
            default:
                os_log(.error, log: logger, "❓ Unknown format: %d (0x%02x)", format, format)
                shouldAccept = false
            }
            
            if !shouldAccept {
                os_log(.info, log: logger, "🔄 Rejecting %{public}s format, requesting AAC transcode", formatName)
                slimProtoClient?.sendStatus("STMn")
                return
            }
            
            let serverElapsedTime = extractServerElapsedTime(from: payload)
            
            if payload.count > 24 {
                let httpData = payload.subdata(in: 24..<payload.count)
                if let httpRequest = String(data: httpData, encoding: .utf8) {
                    os_log(.info, log: logger, "HTTP request for %{public}s: %{public}s", formatName, httpRequest)
                    
                    if let url = extractURLFromHTTPRequest(httpRequest) {
                        os_log(.info, log: logger, "✅ Accepting %{public}s stream: %{public}s", formatName, url)
                        
                        switch streamCommand {
                        case UInt8(ascii: "s"): // start
                            handleStartCommand(url: url, format: formatName, startTime: serverElapsedTime)
                        case UInt8(ascii: "p"): // pause
                            handlePauseCommand()
                        case UInt8(ascii: "u"): // unpause
                            handleUnpauseCommand()
                        case UInt8(ascii: "q"): // stop
                            handleStopCommand()
                        case UInt8(ascii: "t"): // status request
                            handleStatusRequest(payload)
                        case UInt8(ascii: "f"): // flush
                            handleFlushCommand()
                        default:
                            slimProtoClient?.sendStatus("STMt")
                        }
                    } else {
                        slimProtoClient?.sendStatus("STMn")
                    }
                } else {
                    slimProtoClient?.sendStatus("STMn")
                }
            } else {
                // Handle commands without HTTP data
                os_log(.error, log: logger, "⚠️ Stream command '%{public}s' has no HTTP data - handling as control command", commandChar)
                
                if streamCommand == UInt8(ascii: "t") && payload.count >= 24 {
                    let timestampData = payload.subdata(in: 16..<20)
                    serverTimestamp = timestampData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    slimProtoClient?.setServerTimestamp(serverTimestamp)
                    os_log(.debug, log: logger, "Extracted server timestamp: %d", serverTimestamp)
                }
                
                switch streamCommand {
                case UInt8(ascii: "s"): // start - but no URL!
                    os_log(.error, log: logger, "🚨 Server sent START command but no HTTP data!")
                    slimProtoClient?.sendStatus("STMn")
                case UInt8(ascii: "p"): // pause
                    handlePauseCommand()
                case UInt8(ascii: "u"): // unpause
                    handleUnpauseCommand()
                case UInt8(ascii: "q"): // stop
                    handleStopCommand()
                case UInt8(ascii: "t"): // status request
                    handleStatusRequest(payload)
                case UInt8(ascii: "f"): // flush
                    handleFlushCommand()
                default:
                    os_log(.error, log: logger, "❓ Unknown stream command: '%{public}s' (%d)", commandChar, streamCommand)
                    slimProtoClient?.sendStatus("STMt")
                }
            }
        } else {
            slimProtoClient?.sendStatus("STMn")
        }
    }
    
    // MARK: - Individual Command Handlers (existing code...)
    private func handleStartCommand(url: String, format: String, startTime: Double) {
        os_log(.info, log: logger, "▶️ Starting %{public}s stream from %.2f", format, startTime)
        
        // Track server's time reference but don't try to maintain it locally
        serverStartTime = Date()
        serverStartPosition = startTime
        lastKnownPosition = startTime
        
        isStreamPaused = false
        isPausedByLockScreen = false
        isStreamActive = true
        
        delegate?.didStartStream(url: url, format: format, startTime: startTime)
        
        // REMOVED: All the STMc/STMs sending - let coordinator handle it
        os_log(.info, log: logger, "✅ Stream start delegated - server manages position")
    }
    
    private func handlePauseCommand() {
        os_log(.info, log: logger, "⏸️ Server pause command")
        
        // Don't track position - server knows where we are
        isStreamPaused = true
        isPausedByLockScreen = true
        
        delegate?.didPauseStream()
        // REMOVED: client status sending - let coordinator handle it
    }
    
    func getCurrentAudioTime() -> Double {
        // Access audio manager through the coordinator delegate
        if let coordinator = delegate as? SlimProtoCoordinator {
            // We need to add a public method to get audio time from coordinator
            return coordinator.getCurrentAudioTime()
        }
        return lastKnownPosition
    }
    
    func syncWithServerPosition(_ serverPosition: Double, isPlaying: Bool) {
        // Just update our tracking variables
        lastKnownPosition = serverPosition
        isStreamPaused = !isPlaying
        
        // Update server reference time
        if isPlaying {
            serverStartTime = Date()
            serverStartPosition = serverPosition
        } else {
            serverStartTime = nil
        }
        
        os_log(.info, log: logger, "🔄 Synced to server position: %.2f", serverPosition)
    }
    
    private func handleUnpauseCommand() {
        os_log(.info, log: logger, "▶️ Server unpause command")
        
        // Don't track position - server will tell us if we need to seek
        isStreamPaused = false
        isPausedByLockScreen = false
        
        delegate?.didResumeStream()
        // REMOVED: client status sending - let coordinator handle it
    }
    
    private func handleStopCommand() {
        os_log(.info, log: logger, "⏹️ Server stop command")
        isPausedByLockScreen = false
        isStreamActive = false
        lastKnownPosition = 0.0
        
        delegate?.didStopStream()
        slimProtoClient?.sendStatus("STMf")
    }
    
    private func handleFlushCommand() {
        os_log(.info, log: logger, "🗑️ Server flush command")
        isPausedByLockScreen = false
        isStreamActive = false
        lastKnownPosition = 0.0
        
        delegate?.didStopStream()
        slimProtoClient?.sendStatus("STMf")
    }
    
    private func handleStatusRequest(_ payload: Data) {
        os_log(.debug, log: logger, "🔄 Server status request")
        
        if payload.count >= 24 {
            let timestampData = payload.subdata(in: 16..<20)
            serverTimestamp = timestampData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            slimProtoClient?.setServerTimestamp(serverTimestamp)
            os_log(.debug, log: logger, "Extracted server timestamp: %d", serverTimestamp)
        }
        
        delegate?.didReceiveStatusRequest()
        
        if isPausedByLockScreen {
            slimProtoClient?.sendStatus("STMp")
            os_log(.info, log: logger, "📍 Responding to status request with PAUSE status")
        } else {
            slimProtoClient?.sendStatus("STMt")
            os_log(.info, log: logger, "📍 Responding to status request with TIMER status")
        }
    }
    
    // MARK: - Utility Methods
    private func extractServerElapsedTime(from payload: Data) -> Double {
        guard payload.count >= 24 else { return 0.0 }
        
        let elapsedData = payload.subdata(in: 16..<20)
        let elapsedSeconds = elapsedData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        if elapsedSeconds > 0 && elapsedSeconds < 3600 {
            os_log(.info, log: logger, "🔄 Extracted valid server elapsed time: %d seconds", elapsedSeconds)
            return Double(elapsedSeconds)
        } else if elapsedSeconds > 0 {
            os_log(.error, log: logger, "⚠️ Server elapsed time seems too high: %d seconds - ignoring", elapsedSeconds)
        }
        
        return 0.0
    }
    
    func getServerProvidedTime() -> Double {
        // Always prefer server position when paused
        if isPausedByLockScreen {
            return lastKnownPosition
        }
        
        // For playing state, only calculate if we have a recent server reference
        guard let startTime = serverStartTime else {
            return lastKnownPosition
        }
        
        // Only trust local calculation for short periods (< 30 seconds)
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed < 30.0 {
            return serverStartPosition + elapsed
        } else {
            // Older than 30 seconds - don't trust local calculation
            return lastKnownPosition
        }
    }

    
    private func extractURLFromHTTPRequest(_ httpRequest: String) -> String? {
        let lines = httpRequest.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        
        let path = parts[1]
        let webPort = settings.serverWebPort
        let host = settings.serverHost
        let fullURL = "http://\(host):\(webPort)\(path)"
        
        os_log(.info, log: logger, "🔍 Extracted stream URL: %{public}s", fullURL)
        return fullURL
    }
    
    // MARK: - Public Interface
    func notifyTrackEnded() {
        os_log(.info, log: logger, "🎵 Track ended - sending STMd (decoder ready) to server")
        
        // CRITICAL: Reset all tracking state first
        isStreamActive = false
        isStreamPaused = false
        isPausedByLockScreen = false
        lastKnownPosition = 0.0
        serverStartTime = nil
        serverStartPosition = 0.0
        
        // Send STMd (decoder ready) - this tells LMS we finished the track and are ready for next
        slimProtoClient?.sendStatus("STMd")
        
        os_log(.info, log: logger, "✅ STMd sent - server should initiate next track")
    }
    
    func updatePlaybackPosition(_ position: Double) {
        lastKnownPosition = position
        // REMOVED: All the complex state management
    }
    
    var streamState: String {
        if !isStreamActive {
            return "Stopped"
        } else if isPausedByLockScreen {
            return "Paused"
        } else {
            return "Playing"
        }
    }
}
