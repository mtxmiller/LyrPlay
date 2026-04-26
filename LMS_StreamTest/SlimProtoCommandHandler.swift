// File: SlimProtoCommandHandler.swift
// UPDATED: Native FLAC support enabled with StreamingKit
import Foundation
import os.log

protocol SlimProtoCommandHandlerDelegate: AnyObject {
    func didStartStream(url: String, format: String, startTime: Double, replayGain: Float)
    func didStartDirectStream(url: String, format: String, startTime: Double, replayGain: Float) // NEW: For gapless push streams
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

            // Too spammy - uncomment only for debugging STRM commands
            // os_log(.debug, log: logger, "🔍 STRM autostart byte: %d (0x%02X) - '0'=%d '3'=%d",
            //        autostart, autostart, Character("0").asciiValue!, Character("3").asciiValue!)

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
                    os_log(.info, log: logger, "✅ Server offering FLAC")
                }
                
            case 112: // 'p' = PCM
                formatName = "PCM"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering PCM")
                }

            case 119: // 'w' = WAV
                formatName = "WAV"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering WAV - native BASS support!")
                }

            case 111: // 'o' = OGG
                formatName = "OGG"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering OGG - Bass native support!")
                }
                
            case 117: // 'u' = Opus
                formatName = "Opus"
                shouldAccept = true
                if streamCommand != UInt8(ascii: "t") {
                    os_log(.info, log: logger, "✅ Server offering Opus - Bass native support!")
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
                    
                    if let extractedURL = extractURLFromHTTPRequest(httpRequest) {
                        // Inject credentials into URL for password-protected LMS servers
                        let url = SettingsManager.shared.injectCredentialsIntoURL(extractedURL)

                        // Log URL with masked credentials for security
                        let maskedURL = url.replacingOccurrences(of: #"://[^:]+:[^@]+@"#, with: "://***:***@", options: .regularExpression)
                        os_log(.info, log: logger, "✅ Accepting %{public}s stream: %{public}s", formatName, maskedURL)

                        // Check if this is a direct stream (autostart < '2') or HTTP stream (autostart >= '2')
                        // Per squeezelite: 0='direct wait', 1='direct play', 2/3='HTTP'
                        let isDirectStream = (autostart < Character("2").asciiValue!)

                        switch streamCommand {
                        case UInt8(ascii: "s"): // start
                            handleStartCommand(url: url, format: formatName, startTime: 0.0, replayGain: replayGainFloat, autostart: autostart)
                        case UInt8(ascii: "p"): // pause (PHASE 4: check for timed pause)
                            // For strm 'p', replay_gain field may contain interval for timed pause (play silence)
                            let interval = replayGainFixed  // Interval in milliseconds
                            handlePauseCommand(interval: interval)
                        case UInt8(ascii: "u"): // unpause (PHASE 2: with timing for sync)
                            // For strm 'u' commands, replay_gain field contains jiffies timestamp (not actual gain)
                            // Extract jiffies from bytes 14-17 (same as replay_gain field)
                            let jiffiesTimestamp = replayGainFixed  // Already extracted above
                            handleUnpauseCommand(jiffies: jiffiesTimestamp)
                        case UInt8(ascii: "a"): // skip ahead (PHASE 4: sync drift correction)
                            // For strm 'a', replay_gain field contains interval to skip ahead (consume buffer)
                            let interval = replayGainFixed  // Interval in milliseconds
                            handleSkipAheadCommand(interval: interval)
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
                case UInt8(ascii: "p"): // pause (PHASE 4: check for timed pause)
                    let interval = replayGainFixed
                    handlePauseCommand(interval: interval)
                case UInt8(ascii: "u"): // unpause (PHASE 2: with timing for sync)
                    // For strm 'u' commands, replay_gain field contains jiffies timestamp
                    let jiffiesTimestamp = replayGainFixed  // Already extracted above
                    handleUnpauseCommand(jiffies: jiffiesTimestamp)
                case UInt8(ascii: "a"): // skip ahead (PHASE 4: sync drift correction)
                    let interval = replayGainFixed
                    handleSkipAheadCommand(interval: interval)
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
    private func handleStartCommand(url: String, format: String, startTime: Double, replayGain: Float, autostart: UInt8) {
        // Autostart values (per squeezelite): 0/1=direct stream, 2/3=HTTP stream
        let streamMode = (autostart < Character("2").asciiValue!) ? "DIRECT" : "HTTP"
        os_log(.info, log: logger, "▶️ Starting %{public}s stream (%{public}s mode, autostart=%d) from %.2f with replayGain %.4f",
               format, streamMode, autostart, startTime, replayGain)

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

        // Route to appropriate playback mode based on autostart
        // Per squeezelite: 0/1=direct stream (gapless), 2/3=HTTP stream (traditional)
        let isDirectStream = (autostart < Character("2").asciiValue!)

        // Route streams based on autostart mode - all formats use same logic
        if isDirectStream {
            // Direct stream - use push stream for gapless (autostart 0 or 1)
            os_log(.info, log: logger, "📊 Routing to DIRECT stream (push stream for gapless)")
            delegate?.didStartDirectStream(url: url, format: format, startTime: startTime, replayGain: replayGain)
        } else {
            // HTTP URL stream - use traditional pull stream (autostart 2 or 3)
            os_log(.info, log: logger, "🌐 Routing to HTTP stream (traditional URL stream)")
            delegate?.didStartStream(url: url, format: format, startTime: startTime, replayGain: replayGain)
        }
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
    
    // PHASE 4: Enhanced pause command with timed pause support for sync drift correction
    private func handlePauseCommand(interval: UInt32 = 0) {
        if interval == 0 {
            // Regular pause (no interval)
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
        } else {
            // Timed pause - play silence for interval milliseconds (sync drift correction)
            let intervalSeconds = TimeInterval(interval) / 1000.0
            os_log(.info, log: logger, "⏸️🔇 Timed pause - play silence for %.3f seconds (drift correction)", intervalSeconds)

            // Forward to coordinator which routes to AudioManager → AudioPlayer
            if let coordinator = delegate as? SlimProtoCoordinator {
                coordinator.playSilence(duration: intervalSeconds)
                os_log(.debug, log: logger, "✅ Timed pause initiated")
            } else {
                os_log(.error, log: logger, "❌ Cannot access coordinator for timed pause - falling back to regular pause")
                isStreamPaused = true
                delegate?.didPauseStream()
            }
        }
    }

    // Skip ahead command for sync drift correction
    private func handleSkipAheadCommand(interval: UInt32) {
        let intervalSeconds = TimeInterval(interval) / 1000.0
        os_log(.info, log: logger, "⏩ Skip ahead - consume buffer for %.3f seconds (drift correction)", intervalSeconds)

        // Forward to coordinator which routes to AudioManager → AudioPlayer
        if let coordinator = delegate as? SlimProtoCoordinator {
            coordinator.skipAhead(duration: intervalSeconds)
            os_log(.debug, log: logger, "✅ Skip ahead initiated")
        } else {
            os_log(.error, log: logger, "❌ Cannot access coordinator for skip ahead")
        }

        // Send acknowledgment
        slimProtoClient?.sendStatus("STMt")
    }
    
    func getCurrentAudioTime() -> Double {
        // Access audio manager through the coordinator delegate
        if let coordinator = delegate as? SlimProtoCoordinator {
            // We need to add a public method to get audio time from coordinator
            return coordinator.getCurrentAudioTime()
        }
        return lastKnownPosition
    }

    // PHASE 2: Enhanced unpause command with synchronized start timing
    func handleUnpauseCommand(jiffies: UInt32 = 0) {
        os_log(.info, log: logger, "▶️ Server unpause command (jiffies: %u)", jiffies)

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

        // PHASE 2+3: Handle synchronized unpause with jiffies timestamp
        if jiffies == 0 {
            // Immediate unpause - no synchronization needed
            os_log(.info, log: logger, "▶️ Immediate unpause (jiffies=0) - starting playback now")
            isStreamPaused = false
            isPausedByLockScreen = false
            delegate?.didResumeStream()
        } else {
            // Synchronized unpause - start at specific jiffies time
            // Convert jiffies (milliseconds) to TimeInterval (seconds)
            let startAtJiffies = TimeInterval(jiffies) / 1000.0

            os_log(.info, log: logger, "🎯 Synchronized unpause - start at jiffies %.3f seconds", startAtJiffies)

            // Call AudioPlayer.startAt() for synchronized multi-room playback
            if let coordinator = delegate as? SlimProtoCoordinator {
                // Forward to coordinator which routes to AudioManager → AudioPlayer
                coordinator.startAtJiffies(startAtJiffies)

                isStreamPaused = false
                isPausedByLockScreen = false

                os_log(.debug, log: logger, "✅ Synchronized start initiated via coordinator")
            } else {
                // Fallback if coordinator not available
                os_log(.error, log: logger, "❌ Cannot access coordinator for synchronized start - falling back to immediate resume")
                isStreamPaused = false
                isPausedByLockScreen = false
                delegate?.didResumeStream()
            }
        }

        // Send STMr (resume acknowledgment) to server
        slimProtoClient?.sendStatus("STMr")
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
            // Too spammy - uncomment only for debugging status responses
            // os_log(.info, log: logger, "📍 Responding to status request with PAUSE status")
        } else {
            slimProtoClient?.sendStatus("STMt", serverTimestamp: serverTimestamp)
            // Too spammy - uncomment only for debugging status responses
            // os_log(.info, log: logger, "📍 Responding to status request with TIMER status")
        }
    }
    
    // MARK: - Utility Methods

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
    // AUDG packet layout (slimserver Squeezebox2.pm pack 'NNCCNN'):
    //   [0..3]  old_gainL (u32, legacy 0-128 — unused)
    //   [4..7]  old_gainR (u32, legacy — unused)
    //   [8]     dvc       (u8, digitalVolumeControl: 1=variable, 0=fixed)
    //   [9]     preamp    (u8, unused)
    //   [10..13] new_gainL (u32, 16.16 fixed point; 65536 = unity)
    //   [14..17] new_gainR (u32, 16.16 fixed point)
    // Mirrors squeezelite's process_audg (slimproto.c): when dvc=0, apply unity gain.
    private func processVolumeCommand(_ payload: Data) {
        guard payload.count >= 18 else {
            os_log(.error, log: logger, "Volume command payload too short: %d bytes", payload.count)
            return
        }

        let dvc = payload[8]
        let newGainL = payload.subdata(in: 10..<14).withUnsafeBytes {
            $0.load(as: UInt32.self).bigEndian
        }

        let normalizedVolume: Float = (dvc == 0) ? 1.0 : Float(newGainL) / 65536.0
        let clampedVolume = max(0.0, min(1.0, normalizedVolume))

        #if DEBUG
        os_log(.debug, log: logger, "🔊 audg dvc=%d gainL=%u → volume=%.3f", dvc, newGainL, clampedVolume)
        #endif

        if let coordinator = delegate as? SlimProtoCoordinator {
            coordinator.setPlayerVolume(clampedVolume)
        }
    }
    
}
