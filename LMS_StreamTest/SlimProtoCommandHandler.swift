// File: SlimProtoCommandHandler.swift
// UPDATED: Native FLAC support enabled with StreamingKit
import Foundation
import os.log

protocol SlimProtoCommandHandlerDelegate: AnyObject {
    func didStartStream(url: String, format: String, startTime: Double, replayGain: Float)
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
    var isPausedByLockScreen = false
    private var lastKnownPosition: Double = 0.0
    private var streamPosition: Double = 0.0
    private var streamDuration: Double = 0.0
    private var streamStartTime: Date?
    private var isStreamPaused: Bool = false
    private var lastStreamUpdate: Date = Date()
    private var serverStartTime: Date?
    private var serverStartPosition: Double = 0.0
    private var isManualSkipInProgress = false
    private var skipProtectionTimer: Timer?
    private var waitingForNextTrack = false  // True after STMd sent, waiting for server's response
    
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
            // In processCommand method - updated versions:
        case "audg":
            processVolumeCommand(command.payload)
            slimProtoClient?.sendStatus("STMt")  // ← Keep as-is (no timestamp needed)

        case "aude":
            slimProtoClient?.sendStatus("STMt")  // ← Keep as-is

        case "vers":
            slimProtoClient?.sendStatus("STMt")  // ← Keep as-is

        case "vfdc":
            if isPausedByLockScreen {
                slimProtoClient?.sendStatus("STMp")  // ← Keep as-is
            } else {
                slimProtoClient?.sendStatus("STMt")  // ← Keep as-is
            }

        case "grfe", "grfb":
            slimProtoClient?.sendStatus("STMt")  // ← Keep as-is

        default:
            slimProtoClient?.sendStatus("STMt")  // ← Keep as-is
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

            // Extract replay_gain from bytes 14-17 (u32_t in 16.16 fixed point format)
            // Pack format: 'aaaaaaaCCCaCCCNnN' where the first N (4 bytes) is replay_gain at offset 14
            let replayGainBytes = payload.subdata(in: 14..<18)
            let replayGainFixed = replayGainBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // Convert 16.16 fixed point to float
            // LMS uses 8.8 fixed point for -30dB to 0dB range for better precision
            // Upper 16 bits = integer part, lower 16 bits = fractional part
            let replayGainFloat = Float(replayGainFixed) / 65536.0

            let commandChar = String(UnicodeScalar(streamCommand) ?? "?")

            // NEW CODE (only log for non-status commands):
            if streamCommand != UInt8(ascii: "t") {  // 't' = status request
                os_log(.info, log: logger, "🎵 Server strm - command: '%{public}s' (%d), format: %d (0x%02x), replayGain: %.4f",
                       commandChar, streamCommand, format, format, replayGainFloat)
            }
            
            // UPDATED: Enhanced format handling with FLAC support
            var formatName = "Unknown"
            var shouldAccept = false
            
            switch format {
            case 97:  // 'a' = AAC
                formatName = "AAC"
                shouldAccept = true
                // OLD: Always logged
                // os_log(.info, log: logger, "✅ Server offering AAC - perfect for iOS!")
                // NEW: Only log for non-status commands
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering AAC - perfect for iOS!")
                }
                
            case 65:  // 'A' = ALAC
                formatName = "ALAC"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering ALAC - excellent for iOS!")
                }
                
            case 109: // 'm' = MP3
                formatName = "MP3"
                shouldAccept = true
                // OLD: Always logged (causing spam)
                // os_log(.info, log: logger, "✅ Server offering MP3 - acceptable fallback")
                // NEW: Only log for non-status commands
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering MP3 - acceptable fallback")
                }
                
            case 102: // 'f' = FLAC
                formatName = "FLAC"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering FLAC - native playback with StreamingKit!")
                }
                
            case 112: // 'p' = PCM
                formatName = "PCM"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering PCM - StreamingKit can handle this")
                }
                
            case 111: // 'o' = OGG
                formatName = "OGG"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering OGG - CBass native support!")
                }
                
            case 117: // 'u' = Opus
                formatName = "Opus"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering Opus - CBass native support!")
                }
                
            default:
                // Only log unknown formats for non-status commands
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.error, log: logger, "❓ Unknown format: %d (0x%02x)", format, format)
                }
                shouldAccept = false
            }
            
            if !shouldAccept {
                os_log(.info, log: logger, "🔄 Rejecting %{public}s format, requesting AAC transcode", formatName)
                slimProtoClient?.sendStatus("STMn")
                return
            }
                        
            if payload.count > 24 {
                let httpData = payload.subdata(in: 24..<payload.count)
                if let httpRequest = String(data: httpData, encoding: .utf8) {
                    os_log(.info, log: logger, "HTTP request for %{public}s: %{public}s", formatName, httpRequest)
                    
                    if let url = extractURLFromHTTPRequest(httpRequest) {
                        os_log(.info, log: logger, "✅ Accepting %{public}s stream: %{public}s", formatName, url)
                        
                        switch streamCommand {
                        case UInt8(ascii: "s"): // start
                            handleStartCommand(url: url, format: formatName, startTime: 0.0, replayGain: replayGainFloat)
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
                if streamCommand != UInt8(ascii: "t") {
                    // Only log for unexpected commands without HTTP data
                    os_log(.error, log: logger, "⚠️ Stream command '%{public}s' has no HTTP data - handling as control command", commandChar)
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
    private func handleStartCommand(url: String, format: String, startTime: Double, replayGain: Float) {
        os_log(.info, log: logger, "▶️ Starting %{public}s stream from %.2f with replayGain %.4f", format, startTime, replayGain)

        // CRITICAL DEBUG: Log if server is sending unexpected start times
        if startTime > 0.1 && startTime < lastKnownPosition - 5.0 {
            os_log(.error, log: logger, "🚨 SERVER ANOMALY: Start time %.2f is much less than last known %.2f",
                   startTime, lastKnownPosition)
        }

        // Send STMf (flush) first, like squeezelite
        slimProtoClient?.sendStatus("STMf")

        // Update state
        serverStartTime = Date()
        serverStartPosition = startTime
        lastKnownPosition = startTime
        isStreamPaused = false
        isPausedByLockScreen = false
        isStreamActive = true
        waitingForNextTrack = false  // Server responded with new track - playlist NOT ended

        delegate?.didStartStream(url: url, format: format, startTime: startTime, replayGain: replayGain)
    }

    // ADD THESE NEW METHODS:
    func handleStreamConnected() {
        os_log(.info, log: logger, "🔗 Stream connected - track transition complete")
        waitingForNextTrack = false  // Reset flag - stream successfully created
        slimProtoClient?.sendStatus("STMc")
    }

    func handleStreamFailed() {
        os_log(.error, log: logger, "❌ Stream creation failed - notifying server")
        slimProtoClient?.sendStatus("STMn")
        waitingForNextTrack = false  // Reset flag - stream failed
    }

    func isInTrackTransition() -> Bool {
        return waitingForNextTrack
    }

    // REMOVED: HTTP header handling - let StreamingKit handle format detection naturally
    // func handleHTTPHeaders(_ headers: String) {
    //     os_log(.info, log: logger, "📄 HTTP headers received")
    //     slimProtoClient?.sendRESP(headers)
    // }
    
    private func handlePauseCommand() {
        os_log(.info, log: logger, "⏸️ Server pause command (last known position: %.2f)", lastKnownPosition)
        
        // Don't track position - server knows where we are
        isStreamPaused = true
        // DON'T automatically set isPausedByLockScreen - only SlimProtoCoordinator should set this
        // for actual lock screen pauses
        
        // CRITICAL FIX: Only update playing state, NOT position when pausing
        // The pause command doesn't include accurate position data
        // Note: SimpleTimeTracker in coordinator handles time tracking
        
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
    
    func handleUnpauseCommand() {
        os_log(.info, log: logger, "▶️ Server unpause command")

        // CRITICAL FIX: Check if we have an active stream before unpausing
        // If no stream (e.g., after disconnect/reconnect), use playlist jump to recover position
        if let coordinator = delegate as? SlimProtoCoordinator {
            if !coordinator.hasActiveStream() {
                os_log(.info, log: logger, "🔄 No active stream after reconnect - using playlist jump for position recovery")

                // CRITICAL: Don't send STMd (that means "next track please")
                // Instead, use playlist jump which tells server to jump to current track at saved position
                // This will trigger strm 's' with correct HTTP URL for current track
                coordinator.performPlaylistRecovery()

                // Don't call didResumeStream() - wait for fresh stream from playlist jump
                isStreamPaused = false
                isPausedByLockScreen = false
                return
            }
        }

        // Normal unpause flow - we have an active stream
        isStreamPaused = false
        isPausedByLockScreen = false

        delegate?.didResumeStream()
        // REMOVED: client status sending - let coordinator handle it
    }
    
    private func handleStopCommand() {
        os_log(.debug, log: logger, "⏹️ Server stop command")
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
        // Extract server timestamp from strm 't' command
        // In strm packets, the replay_gain field (bytes 20-23) contains the timestamp for 't' commands
        var serverTimestamp: UInt32 = 0

        if payload.count >= 24 {
            // Extract the replay_gain field which contains the server timestamp for 't' commands
            let timestampBytes = payload.subdata(in: 20..<24)
            serverTimestamp = timestampBytes.withUnsafeBytes { bytes in
                bytes.load(as: UInt32.self).bigEndian
            }
        }

        // Check if we're waiting for next track (after sending STMd)
        if waitingForNextTrack {
            // Server sent status request instead of new track → playlist ended
            os_log(.info, log: logger, "🛑 End of playlist detected - server sent status request after STMd")
            waitingForNextTrack = false
            slimProtoClient?.sendStatus("STMu", serverTimestamp: serverTimestamp)
            delegate?.didStopStream()
            return
        }

        delegate?.didReceiveStatusRequest()

        if isPausedByLockScreen {
            slimProtoClient?.sendStatus("STMp", serverTimestamp: serverTimestamp)
            os_log(.info, log: logger, "📍 Responding to status request with PAUSE status")
        } else {
            slimProtoClient?.sendStatus("STMt", serverTimestamp: serverTimestamp)
            os_log(.info, log: logger, "📍 Responding to status request with TIMER status")
        }
    }
    
    // MARK: - Utility Methods
    
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
    

    func updateServerTimeFromSlimProto(_ position: Double, isPlaying: Bool) {
        // CRITICAL FIX: Only update position if it's a meaningful value (> 0.1 seconds)
        // SlimProto pause commands often send position 0.00 which is wrong
        
        if position > 0.1 || isPlaying {
            // Valid position or we're playing - update everything
            lastKnownPosition = position
            isStreamPaused = !isPlaying
            
            // Note: SimpleTimeTracker in coordinator handles time updates
            
            os_log(.info, log: logger, "🔄 Updated both SlimProto and ServerTime with position: %.2f", position)
        } else {
            // Invalid/zero position during pause - only update playing state
            isStreamPaused = !isPlaying
            
            // Note: SimpleTimeTracker in coordinator handles playback state
            
            os_log(.info, log: logger, "🔄 Updated playing state only (position %.2f ignored), preserved server time", position)
        }
    }
    private func extractURLFromHTTPRequest(_ httpRequest: String) -> String? {
        let lines = httpRequest.components(separatedBy: "\n")
        guard let firstLine = lines.first else { return nil }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        
        let path = parts[1]
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        let fullURL = "http://\(host):\(webPort)\(path)"
        
        os_log(.info, log: logger, "🔍 Extracted stream URL: %{public}s", fullURL)
        return fullURL
    }
    
    // MARK: - Public Interface
    func notifyTrackEnded() {
        // CRITICAL: Don't send track end signals during manual skips
        if isManualSkipInProgress {
            os_log(.info, log: logger, "🛡️ Track end blocked - manual skip in progress")
            return
        }

        // CRITICAL: Prevent duplicate STMd if we're already waiting for server response
        if waitingForNextTrack {
            os_log(.info, log: logger, "🛡️ Track end blocked - already waiting for server response to previous STMd")
            return
        }

        os_log(.info, log: logger, "🎵 Track ended - sending STMd (decoder ready) to server")

        // Reset all tracking state first
        isStreamActive = false
        isStreamPaused = false
        isPausedByLockScreen = false
        lastKnownPosition = 0.0
        serverStartTime = nil
        serverStartPosition = 0.0

        // Send STMd (decoder ready)
        slimProtoClient?.sendStatus("STMd")

        // Set flag to track that we're waiting for server's response
        waitingForNextTrack = true

        os_log(.info, log: logger, "✅ STMd sent - waiting for server response (next track or playlist end)")
    }
    
    func updatePlaybackPosition(_ position: Double) {
        lastKnownPosition = position
        // REMOVED: All the complex state management
    }
    
    func startSkipProtection() {
        os_log(.info, log: logger, "🛡️ Starting skip protection - blocking track end detection")
        isManualSkipInProgress = true
        
        // Clear any existing timer
        skipProtectionTimer?.invalidate()
        
        // Protect for 5 seconds (enough time for the skip to complete)
        skipProtectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            self?.endSkipProtection()
        }
    }

    private func endSkipProtection() {
        os_log(.info, log: logger, "🛡️ Ending skip protection")
        isManualSkipInProgress = false
        skipProtectionTimer?.invalidate()
        skipProtectionTimer = nil
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
    
    
    // MARK: - Volume Command Processing
    private func processVolumeCommand(_ payload: Data) {
        guard payload.count >= 18 else {
            os_log(.error, log: logger, "Volume command payload too short: %d bytes", payload.count)
            return
        }
        
        // Parse as old format first (more common for squeezelite players)
        // Old format: 0-128 range in first 4 bytes each for L/R
        let leftGainBytes = payload.subdata(in: 0..<4)
        let rightGainBytes = payload.subdata(in: 4..<8)
        
        let leftGain = leftGainBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let rightGain = rightGainBytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        let normalizedVolume: Float
        
        // Detect format: if values are <= 128, it's old format (0-128)
        // If values are much larger (like 65536), it's new format (16.16 fixed point)
        if leftGain <= 128 && rightGain <= 128 {
            // Old format: 0-128 range
            normalizedVolume = Float(leftGain) / 128.0
            // REMOVED: Noisy volume logs - os_log(.debug, log: logger, "🔊 Received audg (OLD format): L=%d R=%d (%.3f)", leftGain, rightGain, normalizedVolume)
        } else {
            // New format: 16.16 fixed point where 65536 = 100%
            normalizedVolume = Float(leftGain) / 65536.0
            // REMOVED: Noisy volume logs - os_log(.debug, log: logger, "🔊 Received audg (NEW format): L=%d R=%d (%.3f)", leftGain, rightGain, normalizedVolume)
        }
        
        let clampedVolume = max(0.0, min(1.0, normalizedVolume))
        
        // Apply volume through coordinator
        if let coordinator = delegate as? SlimProtoCoordinator {
            coordinator.setPlayerVolume(clampedVolume)
        }
    }
    
}
