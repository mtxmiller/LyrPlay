// File: AudioPlayer.swift
// Updated to use StreamingKit for native FLAC support
import Foundation
import StreamingKit
import os.log

protocol AudioPlayerDelegate: AnyObject {
    func audioPlayerDidStartPlaying()
    func audioPlayerDidPause()
    func audioPlayerDidStop()
    func audioPlayerDidReachEnd()
    func audioPlayerTimeDidUpdate(_ time: Double)
    func audioPlayerDidStall()
    func audioPlayerDidReceiveMetadataUpdate()
}

class AudioPlayer: NSObject, ObservableObject {
    
    // MARK: - Core Components (UPDATED)
    private var audioPlayer: STKAudioPlayer!
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioPlayer")
    private let settings = SettingsManager.shared
    
    // MARK: - State Management (UPDATED with track end protection)
    private var lastReportedTime: Double = 0
    private var isIntentionallyPaused = false
    private var isIntentionallyStopped = false
    private var metadataDuration: TimeInterval = 0.0
    
    // CRITICAL: Track end detection protection from REFERENCE
    private var trackEndDetectionEnabled = false
    private var trackStartTime: Date = Date()
    private let minimumTrackDuration: TimeInterval = 5.0 // Minimum 5 seconds before allowing track end detection
    
    // MARK: - Delegation
    weak var delegate: AudioPlayerDelegate?
    
    // MARK: - State Tracking
    private var lastReportedState: STKAudioPlayerState = []
    private var lastTimeUpdateReport: Date = Date()
    private let minimumTimeUpdateInterval: TimeInterval = 1.0  // Max 1 update per second
    
    weak var commandHandler: SlimProtoCommandHandler?

    // REMOVED: private var customURLSessionTask: URLSessionDataTask?
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupStreamingKit()
        os_log(.info, log: logger, "AudioPlayer initialized with StreamingKit")
    }
    
    // MARK: - Core Setup (UPDATED)
    private func setupStreamingKit() {
        let userBufferSize = settings.bufferSize
        let bufferSeconds = Float32(bufferSizeToSeconds(userBufferSize))
        let readBufferSize = UInt32(max(userBufferSize / 4, 262144)) // At least 256KB
        
        // CORRECT: Using the actual struct from your header file
        var options = STKAudioPlayerOptions()
        options.flushQueueOnSeek = true
        options.enableVolumeMixer = true  // We handle volume elsewhere
        options.readBufferSize = readBufferSize
        options.bufferSizeInSeconds = bufferSeconds
        options.secondsRequiredToStartPlaying = Float32(min(Double(bufferSeconds) * 0.3, 2.0)) // Start at 30% or 2s max
        options.gracePeriodAfterSeekInSeconds = 1.0
        options.secondsRequiredToStartPlayingAfterBufferUnderun = Float32(min(Double(bufferSeconds) * 0.5, 3.0)) // Resume at 50% or 3s max
        
        // Create player with properly configured options
        audioPlayer = STKAudioPlayer(options: options)
        audioPlayer.delegate = self
        audioPlayer.meteringEnabled = false
        audioPlayer.volume = 1.0
        
        os_log(.info, log: logger, "✅ StreamingKit configured - Read Buffer: %dKB, Buffer Time: %.1fs, Start: %.1fs",
               readBufferSize / 1024, bufferSeconds, options.secondsRequiredToStartPlaying)
    }

    
    private func bufferSizeToSeconds(_ bufferSizeBytes: Int) -> TimeInterval {
        // FLAC-aware calculation based on actual bitrates
        let estimatedBitrate: Double
        
        // Use higher bitrate estimate since FLAC is prioritized
        if bufferSizeBytes >= 2_097_152 { // 2MB+
            estimatedBitrate = 1_200_000 // 1.2 Mbps - high quality FLAC
        } else if bufferSizeBytes >= 1_048_576 { // 1MB+
            estimatedBitrate = 900_000 // 900 kbps - mixed FLAC/AAC
        } else {
            estimatedBitrate = 600_000 // 600 kbps - mostly compressed
        }
        
        let bytesPerSecond = estimatedBitrate / 8.0
        let bufferSeconds = Double(bufferSizeBytes) / bytesPerSecond
        
        // FLAC needs longer buffer times, minimum 2 seconds
        return max(2.0, min(30.0, bufferSeconds))
    }
    
    // REMOVED: HTTP response handling - no longer needed
    // private func handleHTTPResponse(_ response: URLResponse?) { ... }
    
    // REMOVED: HTTP header interception - StreamingKit handles format detection naturally
    // private func interceptHTTPHeaders(for url: URL) { ... }
    
    // REMOVED: HTTP header formatting - no longer needed
    // private func formatHTTPHeaders(_ response: HTTPURLResponse) -> String { ... }


    
    // MARK: - Stream Playback (SIMPLIFIED)
    func playStream(urlString: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing stream with StreamingKit: %{public}s", urlString)
        
        prepareForNewStream()
        
        // REMOVED: HTTP header interception - let StreamingKit handle format detection naturally
        // interceptHTTPHeaders(for: url)
        
        // Reset track end detection protection
        trackEndDetectionEnabled = false
        trackStartTime = Date()
        
        // Enable track end detection after minimum duration
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumTrackDuration) {
            self.trackEndDetectionEnabled = true
            os_log(.info, log: self.logger, "✅ Track end detection enabled after %.1f seconds", self.minimumTrackDuration)
        }
        
        // StreamingKit handles everything
        audioPlayer.play(url)
        
        os_log(.info, log: logger, "✅ StreamingKit playback started")
    }
    
    func playStreamWithFormat(urlString: String, format: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing %{public}s stream: %{public}s", format, urlString)
        
        prepareForNewStream()
        
        // REMOVED: HTTP header interception - let StreamingKit handle format detection naturally
        // interceptHTTPHeaders(for: url)
        
        // Reset track end detection protection
        trackEndDetectionEnabled = false
        trackStartTime = Date()
        
        // Enable track end detection after minimum duration
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumTrackDuration) {
            self.trackEndDetectionEnabled = true
            os_log(.info, log: self.logger, "✅ Track end detection enabled after %.1f seconds", self.minimumTrackDuration)
        }
        
        // StreamingKit handles the format automatically
        audioPlayer.play(url)
        
        os_log(.info, log: logger, "✅ StreamingKit %{public}s playback started", format)
    }
    
    func playStreamAtPosition(urlString: String, startTime: Double) {
        playStream(urlString: urlString)
        
        if startTime > 0 {
            seekToPosition(startTime)
        }
    }
    
    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String) {
        playStreamWithFormat(urlString: urlString, format: format)
        
        if startTime > 0 {
            seekToPosition(startTime)
        }
    }
    
    // MARK: - Playback Control (UPDATED)
    func play() {
        isIntentionallyPaused = false
        audioPlayer.resume()
        delegate?.audioPlayerDidStartPlaying()
        os_log(.info, log: logger, "▶️ StreamingKit resumed playback")
    }
    
    func pause() {
        isIntentionallyPaused = true
        audioPlayer.pause()
        delegate?.audioPlayerDidPause()
        os_log(.info, log: logger, "⏸️ StreamingKit paused playback")
    }
    
    func stop() {
        isIntentionallyStopped = true
        isIntentionallyPaused = false
        audioPlayer.stop()
        delegate?.audioPlayerDidStop()
        os_log(.info, log: logger, "⏹️ StreamingKit stopped playback")
    }
    
    // MARK: - Time and State (UPDATED)
    func getCurrentTime() -> Double {
        return audioPlayer.progress  // StreamingKit provides this
    }
    
    func getDuration() -> Double {
        // Prefer metadata duration, fallback to StreamingKit
        if metadataDuration > 0 {
            return metadataDuration
        }
        return audioPlayer.duration
    }
    
    func getPosition() -> Float {
        let duration = getDuration()
        let currentTime = getCurrentTime()
        return duration > 0 ? Float(currentTime / duration) : 0.0
    }
    
    func getPlayerState() -> String {
        let state = audioPlayer.state
        
        if state.contains(.error) { return "Failed" }
        if state.contains(.playing) { return "Playing" }
        if state.contains(.paused) { return "Paused" }
        if state.contains(.stopped) { return "Stopped" }
        if state.contains(.buffering) { return "Buffering" }
        
        return "Ready"
    }
    
    // MARK: - Volume Control
    func setVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        audioPlayer.volume = clampedVolume
        // REMOVED: Noisy volume logs - os_log(.debug, log: logger, "🔊 Volume set to: %.2f", clampedVolume)
    }

    func getVolume() -> Float {
        return audioPlayer.volume
    }
    
    func seekToPosition(_ time: Double) {
        audioPlayer.seek(toTime: time)
        lastReportedTime = time
        os_log(.info, log: logger, "🔄 StreamingKit seeked to position: %.2f seconds", time)
    }
    
    // MARK: - Track End Detection (SIMPLIFIED)
    func checkIfTrackEnded() -> Bool {
        // FROM REFERENCE: Remove manual track end checking entirely
        // StreamingKit delegate handles this properly
        return false
    }
    
    // MARK: - Private Helpers
    private func prepareForNewStream() {
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        
        // CRITICAL: Reset track end detection protection
        trackEndDetectionEnabled = false
        trackStartTime = Date()
    }
    
    // MARK: - Metadata
    func setMetadataDuration(_ duration: TimeInterval) {
        // Only log if duration actually changes to avoid spam
        if abs(metadataDuration - duration) > 1.0 {
            os_log(.info, log: logger, "🎵 Metadata duration updated: %.0f seconds", duration)
        }
        metadataDuration = duration
    }
    
    // MARK: - Cleanup
    deinit {
        stop()
        os_log(.info, log: logger, "AudioPlayer deinitialized")
    }
}

// MARK: - STKAudioPlayerDelegate (NEW)
extension AudioPlayer: STKAudioPlayerDelegate {
    
    func audioPlayer(_ audioPlayer: STKAudioPlayer, didStartPlayingQueueItemId queueItemId: NSObject) {
        os_log(.info, log: logger, "▶️ StreamingKit started playing item")
        
        // CRITICAL: Only report if this is a new start, not a resume/seek
        let currentState = audioPlayer.state
        
        if !lastReportedState.contains(.playing) {
            delegate?.audioPlayerDidStartPlaying()
            lastReportedState = currentState
            os_log(.info, log: logger, "✅ Reported start playing to delegate")
        } else {
            os_log(.debug, log: logger, "🔄 Suppressed duplicate start playing event")
        }
    }
    
    // Add this method to the STKAudioPlayerDelegate extension in AudioPlayer.swift
    func audioPlayer(_ audioPlayer: STKAudioPlayer, didReceiveRawAudioData audioData: Data, audioDescription: AudioStreamBasicDescription) {
        // Check for ICY metadata in the stream
        checkForICYMetadata(in: audioData)
    }

    // Add this method to the AudioPlayer class
    private func checkForICYMetadata(in data: Data) {
        // Look for ICY metadata patterns in the audio data
        // This is a simplified implementation - StreamingKit might have better hooks
        
        // Convert data to string to look for metadata
        if let dataString = String(data: data, encoding: .utf8) {
            // Look for common ICY metadata patterns
            if dataString.contains("StreamTitle=") {
                os_log(.info, log: logger, "🎵 ICY metadata detected in stream")
                
                // Notify delegate that metadata might have changed
                DispatchQueue.main.async {
                    self.delegate?.audioPlayerDidReceiveMetadataUpdate()
                }
            }
        }
    }
    
    func audioPlayer(_ audioPlayer: STKAudioPlayer, didFinishBufferingSourceWithQueueItemId queueItemId: NSObject) {
        os_log(.info, log: logger, "📡 StreamingKit finished buffering")
    }
    
    func audioPlayer(_ audioPlayer: STKAudioPlayer, didFinishPlayingQueueItemId queueItemId: NSObject, with stopReason: STKAudioPlayerStopReason, andProgress progress: Double, andDuration duration: Double) {
        
        let reasonString = stopReasonDescription(stopReason)
        os_log(.info, log: logger, "🎵 StreamingKit finished playing - Reason: %{public}s, Progress: %.2f/%.2f", reasonString, progress, duration)
        
        // FIXED: Enhanced track end detection based on REFERENCE implementation
        switch stopReason {
        case .eof: // End of file - natural track end
            if !isIntentionallyPaused && !isIntentionallyStopped {
                os_log(.info, log: logger, "🎵 Track ended naturally (EOF)")
                
                // INTEGRATION POINT: Send STMd (decode ready) through command handler
                commandHandler?.notifyTrackEnded()
                
                DispatchQueue.main.async {
                    self.delegate?.audioPlayerDidReachEnd()
                }
            } else {
                os_log(.info, log: logger, "🎵 Track EOF but end detection disabled or intentional stop")
            }
        case .none:
            // CRITICAL: StreamingKit sometimes reports "none" for natural track ends
            // Check if we have reasonable progress to determine if this was a natural end
            if progress > 10.0 && !isIntentionallyPaused && !isIntentionallyStopped {
                os_log(.info, log: logger, "🎵 Track ended naturally (None reason but good progress: %.2f)", progress)
                
                // INTEGRATION POINT: Send STMd (decode ready) through command handler
                commandHandler?.notifyTrackEnded()
                
                DispatchQueue.main.async {
                    self.delegate?.audioPlayerDidReachEnd()
                }
            } else {
                os_log(.info, log: logger, "🎵 Track stopped with 'None' reason but insufficient progress: %.2f", progress)
            }
        case .userAction: // User stopped
            os_log(.info, log: logger, "👤 Track stopped by user action")
            // No STMd needed for user actions - server initiated the stop
            
        case .error: // Error occurred
            os_log(.error, log: logger, "❌ Track stopped due to error")
            // Only trigger on error if enough time has passed (real error, not startup issue)
            if !isIntentionallyPaused && !isIntentionallyStopped && progress > 5.0 {
                // INTEGRATION POINT: Send STMd even on errors after significant progress
                commandHandler?.notifyTrackEnded()
                
                DispatchQueue.main.async {
                    self.delegate?.audioPlayerDidReachEnd()
                }
            }
        default:
            os_log(.info, log: logger, "🎵 Track stopped with reason: %{public}s, progress: %.2f", stopReasonDescription(stopReason), progress)
            break
        }
    }
    
    func audioPlayer(_ audioPlayer: STKAudioPlayer, stateChanged state: STKAudioPlayerState, previousState: STKAudioPlayerState) {
        let stateString = playerStateDescription(state)
        let previousStateString = playerStateDescription(previousState)
        os_log(.debug, log: logger, "🔄 StreamingKit state changed: %{public}s → %{public}s", previousStateString, stateString)
        
        // INTEGRATION POINT 1: When connection is established
        if state.contains(.buffering) && !previousState.contains(.buffering) {
            os_log(.info, log: logger, "🔗 Stream connection established")
            commandHandler?.handleStreamConnected()  // Sends STMc
        }
        
        // INTEGRATION POINT 2: When playback actually starts
        if state.contains(.playing) && !previousState.contains(.playing) {
            // This is when we should send STMs (track started)
            os_log(.info, log: logger, "🎵 Playback actually started")
            // Note: STMs should be sent by the coordinator after this delegate call
        }
        
        // Handle other state changes...
        switch state {
        case let newState where newState.contains(.playing):
            if !previousState.contains(.playing) {
                delegate?.audioPlayerDidStartPlaying()
            }
        case let newState where newState.contains(.paused):
            if !previousState.contains(.paused) {
                delegate?.audioPlayerDidPause()
            }
        case let newState where newState.contains(.stopped):
            if !previousState.contains(.stopped) {
                delegate?.audioPlayerDidStop()
            }
        default:
            break
        }
    }
    
    func audioPlayer(_ audioPlayer: STKAudioPlayer, unexpectedError errorCode: STKAudioPlayerErrorCode) {
        os_log(.error, log: logger, "❌ StreamingKit unexpected error: %d", errorCode.rawValue)
        delegate?.audioPlayerDidStall()
    }
    
    // MARK: - Helper Methods
    private func stopReasonDescription(_ reason: STKAudioPlayerStopReason) -> String {
        switch reason {
        case .none:
            return "None"
        case .eof:
            return "End of File"
        case .userAction:
            return "User Action"
        case .pendingNext:
            return "Pending Next"
        case .disposed:
            return "Disposed"
        case .error:
            return "Error"
        @unknown default:
            return "Unknown(\(reason.rawValue))"
        }
    }
    
    private func playerStateDescription(_ state: STKAudioPlayerState) -> String {
        var states: [String] = []
        
        if state.contains(.running) { states.append("Running") }
        if state.contains(.playing) { states.append("Playing") }
        if state.contains(.buffering) { states.append("Buffering") }
        if state.contains(.paused) { states.append("Paused") }
        if state.contains(.stopped) { states.append("Stopped") }
        if state.contains(.error) { states.append("Error") }
        if state.contains(.disposed) { states.append("Disposed") }
        
        if states.isEmpty {
            return "Ready"
        }
        
        return states.joined(separator: ", ")
    }
}
