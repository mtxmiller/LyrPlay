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
    
    // MARK: - State Management
    private var lastReportedTime: Double = 0
    private var isIntentionallyPaused = false
    private var isIntentionallyStopped = false
    private var metadataDuration: TimeInterval = 0.0
    
    // MARK: - Delegation
    weak var delegate: AudioPlayerDelegate?
    
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
        delegate?.audioPlayerDidStartPlaying()
    }
    
    func audioPlayer(_ audioPlayer: STKAudioPlayer, didFinishBufferingSourceWithQueueItemId queueItemId: NSObject) {
        os_log(.info, log: logger, "📡 StreamingKit finished buffering")
    }
    
    func audioPlayer(_ audioPlayer: STKAudioPlayer, didFinishPlayingQueueItemId queueItemId: NSObject, with stopReason: STKAudioPlayerStopReason, andProgress progress: Double, andDuration duration: Double) {
        
        let reasonString = stopReasonDescription(stopReason)
        os_log(.info, log: logger, "🎵 StreamingKit finished playing - Reason: %{public}s, Progress: %.2f/%.2f", reasonString, progress, duration)
        
        // SIMPLIFIED: Trust StreamingKit's stop reason (from reference)
        switch stopReason {
        case .eof: // Natural track end
            if !isIntentionallyPaused && !isIntentionallyStopped {
                os_log(.info, log: logger, "🎵 Track ended naturally (EOF)")
                DispatchQueue.main.async {
                    self.delegate?.audioPlayerDidReachEnd()
                }
            }
        case .userAction: // User stopped
            os_log(.info, log: logger, "👤 Track stopped by user action")
            delegate?.audioPlayerDidStop()
        case .error: // Error occurred
            os_log(.error, log: logger, "❌ Track stopped due to error")
            delegate?.audioPlayerDidStall()
        default:
            os_log(.info, log: logger, "🎵 Track stopped with reason: %{public}s", stopReasonDescription(stopReason))
            break
        }
    }
    
    func audioPlayer(_ audioPlayer: STKAudioPlayer, stateChanged state: STKAudioPlayerState, previousState: STKAudioPlayerState) {
        let stateString = playerStateDescription(state)
        let previousStateString = playerStateDescription(previousState)
        os_log(.debug, log: logger, "🔄 StreamingKit state changed: %{public}s → %{public}s", previousStateString, stateString)
        
        // Handle state changes for time updates
        let currentTime = getCurrentTime()
        delegate?.audioPlayerTimeDidUpdate(currentTime)
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
