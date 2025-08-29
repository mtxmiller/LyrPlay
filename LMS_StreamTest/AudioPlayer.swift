// File: AudioPlayer.swift
// Updated to use AVPlayer for universal platform support
import Foundation
import AVFoundation
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
    private var avPlayer: AVPlayer!
    private var avPlayerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var hasObservers = false
    
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
    private var playerState: PlayerState = .stopped
    private var lastTimeUpdateReport: Date = Date()
    private let minimumTimeUpdateInterval: TimeInterval = 1.0  // Max 1 update per second
    
    private enum PlayerState {
        case stopped, playing, paused, buffering, error
        
        var description: String {
            switch self {
            case .stopped: return "Stopped"
            case .playing: return "Playing"
            case .paused: return "Paused"
            case .buffering: return "Buffering"
            case .error: return "Error"
            }
        }
    }
    
    weak var commandHandler: SlimProtoCommandHandler?

    // REMOVED: private var customURLSessionTask: URLSessionDataTask?
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupAVPlayer()
        os_log(.info, log: logger, "AudioPlayer initialized with AVPlayer")
    }
    
    // MARK: - Core Setup (UPDATED)
    private func setupAVPlayer() {
        avPlayer = AVPlayer()
        avPlayer.volume = 1.0
        
        os_log(.info, log: logger, "✅ AVPlayer configured")
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
        
        os_log(.info, log: logger, "🎵 Playing stream with AVPlayer: %{public}s", urlString)
        
        prepareForNewStream()
        
        // Reset track end detection protection
        trackEndDetectionEnabled = false
        trackStartTime = Date()
        
        // Enable track end detection after minimum duration
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumTrackDuration) {
            self.trackEndDetectionEnabled = true
            os_log(.info, log: self.logger, "✅ Track end detection enabled after %.1f seconds", self.minimumTrackDuration)
        }
        
        // AVPlayer setup
        let playerItem = AVPlayerItem(url: url)
        avPlayerItem = playerItem
        avPlayer.replaceCurrentItem(with: playerItem)
        setupPlayerItemObservers(playerItem)
        avPlayer.play()
        
        os_log(.info, log: logger, "✅ AVPlayer playback started")
    }
    
    func playStreamWithFormat(urlString: String, format: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing %{public}s stream: %{public}s", format, urlString)
        
        prepareForNewStream()
        
        // Reset track end detection protection
        trackEndDetectionEnabled = false
        trackStartTime = Date()
        
        // Enable track end detection after minimum duration
        DispatchQueue.main.asyncAfter(deadline: .now() + minimumTrackDuration) {
            self.trackEndDetectionEnabled = true
            os_log(.info, log: self.logger, "✅ Track end detection enabled after %.1f seconds", self.minimumTrackDuration)
        }
        
        // AVPlayer setup
        let playerItem = AVPlayerItem(url: url)
        avPlayerItem = playerItem
        avPlayer.replaceCurrentItem(with: playerItem)
        setupPlayerItemObservers(playerItem)
        avPlayer.play()
        
        os_log(.info, log: logger, "✅ AVPlayer %{public}s playback started", format)
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
        avPlayer.play()
        delegate?.audioPlayerDidStartPlaying()
        os_log(.info, log: logger, "▶️ AVPlayer resumed playback")
    }
    
    func pause() {
        isIntentionallyPaused = true
        avPlayer.pause()
        delegate?.audioPlayerDidPause()
        os_log(.info, log: logger, "⏸️ AVPlayer paused playback")
    }
    
    func stop() {
        isIntentionallyStopped = true
        isIntentionallyPaused = false
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        delegate?.audioPlayerDidStop()
        os_log(.debug, log: logger, "⏹️ AVPlayer stopped playback")
    }
    
    // MARK: - Time and State (UPDATED)
    func getCurrentTime() -> Double {
        return avPlayer.currentTime().seconds
    }
    
    func getDuration() -> Double {
        // Prefer metadata duration, fallback to AVPlayer
        if metadataDuration > 0 {
            return metadataDuration
        }
        guard let duration = avPlayerItem?.duration else { return 0.0 }
        return duration.isIndefinite ? 0.0 : duration.seconds
    }
    
    func getPosition() -> Float {
        let duration = getDuration()
        let currentTime = getCurrentTime()
        return duration > 0 ? Float(currentTime / duration) : 0.0
    }
    
    func getPlayerState() -> String {
        switch playerState {
        case .error: return "Failed"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .buffering: return "Buffering"
        }
    }
    
    // MARK: - Volume Control
    func setVolume(_ volume: Float) {
        let clampedVolume = max(0.0, min(1.0, volume))
        avPlayer.volume = clampedVolume
    }

    func getVolume() -> Float {
        return avPlayer.volume
    }
    
    func seekToPosition(_ time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        avPlayer.seek(to: cmTime)
        lastReportedTime = time
        os_log(.info, log: logger, "🔄 AVPlayer seeked to position: %.2f seconds", time)
    }
    
    // MARK: - Track End Detection (SIMPLIFIED)
    func checkIfTrackEnded() -> Bool {
        // AVPlayer delegate handles this properly
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
    
    private func setupPlayerItemObservers(_ playerItem: AVPlayerItem) {
        // Clean up any existing observers first
        cleanupPlayerItemObservers()
        
        // Track end detection
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        
        // Stalling detection
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemStalled),
            name: .AVPlayerItemPlaybackStalled,
            object: playerItem
        )
        
        // Time updates
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            self?.handleTimeUpdate(time.seconds)
        }
        
        // Player state observation
        avPlayer.addObserver(self, forKeyPath: "timeControlStatus", options: [.new, .old], context: nil)
        hasObservers = true
    }
    
    private func cleanupPlayerItemObservers() {
        NotificationCenter.default.removeObserver(self)
        if let observer = timeObserver {
            avPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        // Only remove KVO observer if it was added
        if hasObservers {
            avPlayer.removeObserver(self, forKeyPath: "timeControlStatus")
            hasObservers = false
        }
    }
    
    @objc private func playerItemDidReachEnd() {
        if !isIntentionallyPaused && !isIntentionallyStopped && trackEndDetectionEnabled {
            os_log(.info, log: logger, "🎵 Track ended naturally")
            commandHandler?.notifyTrackEnded()
            DispatchQueue.main.async {
                self.delegate?.audioPlayerDidReachEnd()
            }
        }
    }
    
    @objc private func playerItemStalled() {
        os_log(.info, log: logger, "📡 AVPlayer stalled")
        delegate?.audioPlayerDidStall()
    }
    
    private func handleTimeUpdate(_ time: Double) {
        let now = Date()
        if now.timeIntervalSince(lastTimeUpdateReport) >= minimumTimeUpdateInterval {
            lastReportedTime = time
            lastTimeUpdateReport = now
            delegate?.audioPlayerTimeDidUpdate(time)
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "timeControlStatus" else { return }
        
        DispatchQueue.main.async {
            switch self.avPlayer.timeControlStatus {
            case .playing:
                self.handlePlayerStateChange(.playing)
            case .paused:
                self.handlePlayerStateChange(.paused)
            case .waitingToPlayAtSpecifiedRate:
                self.handlePlayerStateChange(.buffering)
            @unknown default:
                break
            }
        }
    }
    
    private func handlePlayerStateChange(_ newState: PlayerState) {
        guard newState != playerState else { return }
        
        let oldState = playerState
        playerState = newState
        
        os_log(.debug, log: logger, "🔄 AVPlayer state changed: %{public}s → %{public}s", oldState.description, newState.description)
        
        switch newState {
        case .playing:
            if oldState != .playing {
                os_log(.info, log: logger, "🎵 Playback actually started")
                commandHandler?.handleStreamConnected()
                delegate?.audioPlayerDidStartPlaying()
            }
        case .paused:
            delegate?.audioPlayerDidPause()
        case .stopped:
            delegate?.audioPlayerDidStop()
        case .buffering:
            delegate?.audioPlayerDidStall()
        case .error:
            delegate?.audioPlayerDidStall()
        }
    }
    
    // MARK: - Metadata
    func setMetadataDuration(_ duration: TimeInterval) {
        // CRITICAL FIX: Don't overwrite existing duration with 0.0
        if duration > 0.0 {
            // Only log if duration actually changes to avoid spam
            if abs(metadataDuration - duration) > 1.0 {
                os_log(.info, log: logger, "🎵 Metadata duration updated: %.0f seconds", duration)
            }
            metadataDuration = duration
        } else if metadataDuration > 0.0 {
            // Keep existing duration, don't overwrite with 0.0
            os_log(.debug, log: logger, "🎵 Preserving existing duration %.0f seconds (ignoring 0.0)", metadataDuration)
        }
    }
    
    // MARK: - Cleanup
    deinit {
        cleanupPlayerItemObservers()
        stop()
        os_log(.info, log: logger, "AudioPlayer deinitialized")
    }
}
