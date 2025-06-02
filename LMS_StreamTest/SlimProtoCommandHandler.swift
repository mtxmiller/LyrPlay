// File: SlimProtoCommandHandler.swift
// Updated with working logic from reference client
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
    private var isPausedByLockScreen = false // Match reference naming
    private var serverTimestamp: UInt32 = 0
    private var lastKnownPosition: Double = 0.0
    
    // MARK: - Delegation
    weak var delegate: SlimProtoCommandHandlerDelegate?
    weak var slimProtoClient: SlimProtoClient?
    
    // MARK: - Initialization
    init() {
        os_log(.info, log: logger, "SlimProtoCommandHandler initialized")
    }
    
    // MARK: - Command Processing (from reference)
    func processCommand(_ command: SlimProtoCommand) {
        switch command.type {
        case "strm":
            processServerCommand(command.type, payload: command.payload)
        case "audg", "aude":
            slimProtoClient?.sendStatus("STMt") // Acknowledge with heartbeat
        case "stat":
            // Respond to STAT requests based on actual state
            if isPausedByLockScreen {
                slimProtoClient?.sendStatus("STMp") // Send pause status when paused
                os_log(.info, log: logger, "📍 STAT request - responding with PAUSE status")
            } else {
                slimProtoClient?.sendStatus("STMt") // Timer/heartbeat
            }
        case "vers":
            slimProtoClient?.sendStatus("STMt") // Acknowledge with heartbeat
        case "vfdc":
            // Respond to VFD commands based on actual state
            if isPausedByLockScreen {
                slimProtoClient?.sendStatus("STMp") // Send pause status when paused
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
    
    // MARK: - Stream Command Processing (from reference)
    private func processServerCommand(_ command: String, payload: Data) {
        guard command == "strm" else { return }
        
        if payload.count >= 24 {
            let streamCommand = payload[0]
            let autostart = payload[1]
            let format = payload[2]
            
            let commandChar = String(UnicodeScalar(streamCommand) ?? "?")
            os_log(.info, log: logger, "🎵 Server strm - command: '%{public}s' (%d), format: %d (0x%02x)",
                   commandChar, streamCommand, format, format)
            
            // Enhanced format handling (from reference)
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
                slimProtoClient?.sendStatus("STMn") // Not supported - triggers format renegotiation
                return
            }
            
            // Extract server elapsed time for stream pickup (from reference)
            let serverElapsedTime = extractServerElapsedTime(from: payload)
            
            // Extract HTTP request from remaining payload
            if payload.count > 24 {
                let httpData = payload.subdata(in: 24..<payload.count)
                if let httpRequest = String(data: httpData, encoding: .utf8) {
                    os_log(.info, log: logger, "HTTP request for %{public}s: %{public}s", formatName, httpRequest)
                    
                    // Parse the URL from the HTTP request
                    if let url = extractURLFromHTTPRequest(httpRequest) {
                        os_log(.info, log: logger, "✅ Accepting %{public}s stream: %{public}s", formatName, url)
                        
                        // Handle different stream commands (from reference)
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
                            slimProtoClient?.sendStatus("STMt") // Generic status
                        }
                    } else {
                        slimProtoClient?.sendStatus("STMn") // Not supported/error
                    }
                } else {
                    slimProtoClient?.sendStatus("STMn") // Not supported/error
                }
            } else {
                // Handle commands that don't need URLs (from reference)
                os_log(.error, log: logger, "⚠️ Stream command '%{public}s' has no HTTP data - handling as control command", commandChar)
                
                // Extract server timestamp from the payload
                if streamCommand == UInt8(ascii: "t") && payload.count >= 24 {
                    let timestampData = payload.subdata(in: 16..<20)
                    serverTimestamp = timestampData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    slimProtoClient?.setServerTimestamp(serverTimestamp)
                    os_log(.debug, log: logger, "Extracted server timestamp: %d", serverTimestamp)
                }
                
                switch streamCommand {
                case UInt8(ascii: "s"): // start - but no URL!
                    os_log(.error, log: logger, "🚨 Server sent START command but no HTTP data! This shouldn't happen.")
                    slimProtoClient?.sendStatus("STMn") // Not supported - request proper stream
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
                    slimProtoClient?.sendStatus("STMt") // Default to timer status
                }
            }
        } else {
            slimProtoClient?.sendStatus("STMn") // Not supported
        }
    }
    
    // MARK: - Individual Command Handlers (from reference)
    private func handleStartCommand(url: String, format: String, startTime: Double) {
        os_log(.info, log: logger, "▶️ Starting %{public}s stream playback", format)
        isPausedByLockScreen = false
        isStreamActive = true
        
        // Notify delegate
        delegate?.didStartStream(url: url, format: format, startTime: startTime)
        
        // Send acknowledgments (from reference)
        slimProtoClient?.sendStatus("STMc") // Connect - acknowledge stream start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.slimProtoClient?.sendStatus("STMs") // Stream started
        }
    }
    
    private func handlePauseCommand() {
        os_log(.info, log: logger, "⏸️ Server pause command")
        isPausedByLockScreen = true
        lastKnownPosition = getCurrentPlaybackTime() ?? 0.0
        
        delegate?.didPauseStream()
        slimProtoClient?.sendStatus("STMp") // Paused
    }
    
    private func handleUnpauseCommand() {
        os_log(.info, log: logger, "▶️ Server unpause command")
        isPausedByLockScreen = false
        
        delegate?.didResumeStream()
        slimProtoClient?.sendStatus("STMr") // Resume
    }
    
    private func handleStopCommand() {
        os_log(.info, log: logger, "⏹️ Server stop command")
        isPausedByLockScreen = false
        isStreamActive = false
        lastKnownPosition = 0.0
        
        delegate?.didStopStream()
        slimProtoClient?.sendStatus("STMf") // Flushed/stopped
    }
    
    private func handleFlushCommand() {
        os_log(.info, log: logger, "🗑️ Server flush command")
        isPausedByLockScreen = false
        isStreamActive = false
        lastKnownPosition = 0.0
        
        delegate?.didStopStream()
        slimProtoClient?.sendStatus("STMf") // Flushed
    }
    
    private func handleStatusRequest(_ payload: Data) {
        os_log(.debug, log: logger, "🔄 Server status request")
        
        // Extract server timestamp for echo back (from reference)
        if payload.count >= 24 {
            let timestampData = payload.subdata(in: 16..<20)
            serverTimestamp = timestampData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            slimProtoClient?.setServerTimestamp(serverTimestamp)
            os_log(.debug, log: logger, "Extracted server timestamp: %d", serverTimestamp)
        }
        
        delegate?.didReceiveStatusRequest()
        
        // Respond based on our actual state (from reference)
        if isPausedByLockScreen {
            slimProtoClient?.sendStatus("STMp") // Send PAUSE status
            os_log(.info, log: logger, "📍 Responding to status request with PAUSE status")
        } else {
            slimProtoClient?.sendStatus("STMt") // Timer/heartbeat status
            os_log(.info, log: logger, "📍 Responding to status request with TIMER status")
        }
    }
    
    // MARK: - Utility Methods (from reference)
    private func extractServerElapsedTime(from payload: Data) -> Double {
        guard payload.count >= 24 else { return 0.0 }
        
        // Try to extract from replay_gain field (bytes 16-19) as elapsed seconds
        let elapsedData = payload.subdata(in: 16..<20)
        let elapsedSeconds = elapsedData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        // Much more restrictive sanity check - elapsed time shouldn't be more than 1 hour
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
        let webPort = settings.serverWebPort
        let host = settings.serverHost
        let fullURL = "http://\(host):\(webPort)\(path)"
        
        os_log(.info, log: logger, "🔍 Extracted stream URL: %{public}s", fullURL)
        
        return fullURL
    }
    
    // MARK: - Public Interface
    func notifyTrackEnded() {
        os_log(.info, log: logger, "🎵 Track ended - sending STMd to request next track")
        isStreamActive = false
        lastKnownPosition = 0.0
        slimProtoClient?.sendStatus("STMd") // Decoder ready - request next track
    }
    
    // Method to be called by coordinator when audio manager reports time updates
    func updatePlaybackPosition(_ position: Double) {
        if !isPausedByLockScreen {
            lastKnownPosition = position
        }
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
    
    // MARK: - Audio Manager Integration
    private func getCurrentPlaybackTime() -> Double? {
        // This will be enhanced to get actual time from audio manager via coordinator
        return lastKnownPosition
    }
}
