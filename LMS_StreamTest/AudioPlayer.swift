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
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupStreamingKit()
        os_log(.info, log: logger, "AudioPlayer initialized with StreamingKit")
    }
    
    // MARK: - Core Setup (UPDATED)
    private func setupStreamingKit() {
        audioPlayer = STKAudioPlayer()
        audioPlayer.delegate = self
        audioPlayer.meteringEnabled = false // Better performance
        audioPlayer.volume = 1.0
        
        os_log(.info, log: logger, "✅ StreamingKit AudioPlayer initialized")
    }
    
    // MARK: - Stream Playback (SIMPLIFIED)
    func playStream(urlString: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing stream with StreamingKit: %{public}s", urlString)
        
        prepareForNewStream()
        
        // CRITICAL: Reset track end detection protection from REFERENCE
        trackEndDetectionEnabled = false
        trackStartTime = Date()
        
        // Enable track end detection after minimum duration
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumTrackDuration) {
            self.trackEndDetectionEnabled = true
            os_log(.info, log: self.logger, "✅ Track end detection enabled after %.1f seconds", self.minimumTrackDuration)
        }
        
        // SIMPLE: StreamingKit handles everything
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
        
        // CRITICAL: Reset track end detection protection from REFERENCE
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
                DispatchQueue.main.async {
                    self.delegate?.audioPlayerDidReachEnd()
                }
            } else {
                os_log(.info, log: logger, "🎵 Track stopped with 'None' reason but insufficient progress: %.2f", progress)
            }
        case .userAction: // User stopped
            os_log(.info, log: logger, "👤 Track stopped by user action")
        case .error: // Error occurred
            os_log(.error, log: logger, "❌ Track stopped due to error")
            // Only trigger on error if enough time has passed (real error, not startup issue)
            if !isIntentionallyPaused && !isIntentionallyStopped && progress > 5.0 {
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
        
        // CRITICAL: Only report time updates for significant state changes
        // Don't spam time updates during constant buffering state changes
        let shouldReportTimeUpdate: Bool
        
        switch state {
        case let newState where newState.contains(.playing):
            shouldReportTimeUpdate = !previousState.contains(.playing)  // Only when starting to play
        case let newState where newState.contains(.paused):
            shouldReportTimeUpdate = !previousState.contains(.paused)   // Only when starting to pause
        case let newState where newState.contains(.stopped):
            shouldReportTimeUpdate = !previousState.contains(.stopped) // Only when stopping
        default:
            shouldReportTimeUpdate = false  // Don't report during buffering/transitioning
        }
        
        if shouldReportTimeUpdate {
            let currentTime = getCurrentTime()
            delegate?.audioPlayerTimeDidUpdate(currentTime)
            os_log(.debug, log: logger, "📍 Reported time update: %.2f", currentTime)
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
