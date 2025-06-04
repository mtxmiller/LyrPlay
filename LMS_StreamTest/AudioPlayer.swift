// File: AudioPlayer.swift
// Core AVPlayer management and streaming functionality
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
}

class AudioPlayer: NSObject, ObservableObject {
    
    // MARK: - Core Components
    private var player: AVPlayer!
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    
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
        setupAVPlayer()
        os_log(.info, log: logger, "AudioPlayer initialized")
    }
    
    // MARK: - Core Setup
    private func setupAVPlayer() {
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = true
        
        os_log(.info, log: logger, "✅ AVPlayer initialized")
        
        setupTimeObserver()
        setupPlayerItemObservers()
    }
    
    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updatePlaybackTime(time)
        }
        
        os_log(.info, log: logger, "✅ Time observer configured (0.25s intervals)")
    }
    
    private func setupPlayerItemObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlayToEnd),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemStalled),
            name: .AVPlayerItemPlaybackStalled,
            object: nil
        )
        
        os_log(.info, log: logger, "✅ Player item observers configured")
    }
    
    // MARK: - Time Tracking
    private func updatePlaybackTime(_ time: CMTime) {
        let timeInSeconds = CMTimeGetSeconds(time)
        
        guard timeInSeconds.isFinite && timeInSeconds >= 0 else { return }
        
        // Notify delegate of time update
        delegate?.audioPlayerTimeDidUpdate(timeInSeconds)
        
        // Check for track end using metadata duration
        if let item = playerItem,
           item.status == .readyToPlay,
           metadataDuration > 0 {
            
            let remainingTime = metadataDuration - timeInSeconds
            
            if remainingTime <= 1.0 && !isIntentionallyPaused && !isIntentionallyStopped {
                os_log(.info, log: logger, "🎵 Track ending (%.1f seconds remaining)", remainingTime)
                
                if remainingTime <= 0.5 && lastReportedTime > 0 {
                    os_log(.info, log: logger, "🎵 Track ended - notifying delegate")
                    delegate?.audioPlayerDidReachEnd()
                    lastReportedTime = 0
                    return
                }
            }
        }
        
        if timeInSeconds >= 0 {
            lastReportedTime = timeInSeconds
        }
    }
    
    // MARK: - Notification Handlers
    @objc private func playerItemDidReachEnd() {
        os_log(.info, log: logger, "🎵 AVPlayer item reached end")
        
        if !isIntentionallyPaused && !isIntentionallyStopped {
            os_log(.info, log: logger, "🎵 Natural track end - notifying delegate")
            DispatchQueue.main.async {
                self.delegate?.audioPlayerDidReachEnd()
            }
        }
    }
    
    @objc private func playerItemFailedToPlayToEnd(_ notification: Notification) {
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            os_log(.error, log: logger, "❌ Player item failed to play to end: %{public}s", error.localizedDescription)
        }
    }
    
    @objc private func playerItemStalled() {
        os_log(.error, log: logger, "⚠️ Player item playback stalled")
        delegate?.audioPlayerDidStall()
    }
    
    // MARK: - Stream Playback
    func playStream(urlString: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing stream: %{public}s", urlString)
        
        prepareForNewStream()
        createPlayerItem(with: url)
        startPlayback()
    }
    
    func playStreamWithFormat(urlString: String, format: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing %{public}s stream: %{public}s", format, urlString)
        
        prepareForNewStream()
        createPlayerItemWithOptimizations(url: url, format: format)
        startPlayback()
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
    
    // MARK: - Playback Control
    func play() {
        isIntentionallyPaused = false
        player.play()
        delegate?.audioPlayerDidStartPlaying()
        os_log(.info, log: logger, "▶️ Resumed playback")
    }
    
    func pause() {
        isIntentionallyPaused = true
        player.pause()
        delegate?.audioPlayerDidPause()
        os_log(.info, log: logger, "⏸️ Paused playback")
    }
    
    func stop() {
        isIntentionallyStopped = true
        isIntentionallyPaused = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        delegate?.audioPlayerDidStop()
        os_log(.info, log: logger, "⏹️ Stopped playback")
    }
    
    // MARK: - Private Helpers
    private func prepareForNewStream() {
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        
        // Clean up old observers
        if let oldItem = playerItem {
            oldItem.removeObserver(self, forKeyPath: "status")
            oldItem.removeObserver(self, forKeyPath: "loadedTimeRanges")
        }
    }
    
    private func createPlayerItem(with url: URL) {
        playerItem = AVPlayerItem(url: url)
        addKVOObservers()
        player.replaceCurrentItem(with: playerItem)
    }
    
    private func createPlayerItemWithOptimizations(url: URL, format: String) {
        playerItem = AVPlayerItem(url: url)
        
        if let item = playerItem {
            switch format.uppercased() {
            case "ALAC", "FLAC":
                // Lossless optimizations
                item.preferredForwardBufferDuration = 30.0
                item.preferredPeakBitRate = 0
                
            case "AAC":
                // AAC optimizations
                item.preferredForwardBufferDuration = 20.0
                item.preferredPeakBitRate = Double(320 * 1024)
                
            case "MP3":
                // MP3 live stream optimizations
                item.preferredForwardBufferDuration = 25.0
                item.preferredPeakBitRate = 0
                
                if #available(iOS 10.0, *) {
                    item.automaticallyPreservesTimeOffsetFromLive = false
                }
                
            default:
                // Default optimizations
                item.preferredForwardBufferDuration = 8.0
            }
            
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            os_log(.info, log: logger, "🎵 Configured AVPlayerItem for %{public}s streaming", format)
        }
        
        addKVOObservers()
        player.replaceCurrentItem(with: playerItem)
    }
    
    private func addKVOObservers() {
        playerItem?.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        playerItem?.addObserver(self, forKeyPath: "loadedTimeRanges", options: [.new], context: nil)
        os_log(.info, log: logger, "🔍 Added KVO observers to new AVPlayerItem")
    }
    
    private func startPlayback() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.player.play()
            os_log(.info, log: self.logger, "🎵 Playback started - AVPlayer.rate: %.2f", self.player.rate)
        }
    }
    
    private func seekToPosition(_ time: Double) {
        let seekTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        
        player.seek(to: seekTime) { [weak self] finished in
            if finished {
                self?.lastReportedTime = time
                os_log(.info, log: self?.logger ?? OSLog.disabled, "🔄 Seeked to position: %.2f seconds", time)
            }
        }
    }
    
    // MARK: - KVO Observer
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        os_log(.info, log: logger, "🔍 KVO triggered for keyPath: %{public}s", keyPath ?? "nil")
        
        if keyPath == "status", let item = object as? AVPlayerItem {
            handlePlayerItemStatusChange(item)
        } else if keyPath == "loadedTimeRanges", let item = object as? AVPlayerItem {
            handleLoadedTimeRangesChange(item)
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func handlePlayerItemStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .unknown:
            os_log(.info, log: logger, "🎵 AVPlayerItem status: Unknown")
        case .readyToPlay:
            os_log(.info, log: logger, "🎵 AVPlayerItem status: Ready to Play")
            logPlayerItemInfo(item)
            
            // Auto-start for live streams
            DispatchQueue.main.async {
                if self.player.rate == 0 {
                    os_log(.info, log: self.logger, "🎵 Auto-starting playback")
                    self.player.play()
                }
            }
            
        case .failed:
            if let error = item.error {
                os_log(.error, log: logger, "❌ AVPlayerItem failed: %{public}s", error.localizedDescription)
            } else {
                os_log(.error, log: logger, "❌ AVPlayerItem failed: Unknown error")
            }
        @unknown default:
            os_log(.info, log: logger, "🎵 AVPlayerItem status: Unknown case")
        }
    }
    
    private func handleLoadedTimeRangesChange(_ item: AVPlayerItem) {
        let loadedRanges = item.loadedTimeRanges
        if !loadedRanges.isEmpty {
            let timeRange = loadedRanges[0].timeRangeValue
            let loadedDuration = CMTimeGetSeconds(timeRange.duration)
            os_log(.info, log: logger, "🎵 Loaded time range: %.2f seconds", loadedDuration)
            
            // Start playback when sufficient buffer for live streams
            if loadedDuration > 2.0 && self.player.rate == 0 && !self.isIntentionallyPaused {
                os_log(.info, log: logger, "🎵 Sufficient buffer loaded, starting playback")
                DispatchQueue.main.async {
                    self.player.play()
                }
            }
        }
    }
    
    private func logPlayerItemInfo(_ item: AVPlayerItem) {
        let duration = CMTimeGetSeconds(item.duration)
        if duration.isFinite && duration > 0 {
            os_log(.info, log: logger, "🎵 Duration: %.2f seconds", duration)
        } else {
            os_log(.info, log: logger, "🎵 Duration: Invalid or infinite (live stream detected)")
        }
    }
    
    // MARK: - Public Interface
    func getCurrentTime() -> Double {
        let time = player.currentTime()
        return CMTimeGetSeconds(time)
    }
    
    func getDuration() -> Double {
        // First try metadata duration
        if metadataDuration > 0 {
            return metadataDuration
        }
        
        // Fallback to player item duration
        guard let item = playerItem, item.duration.isValid else { return 0.0 }
        let duration = CMTimeGetSeconds(item.duration)
        return duration.isFinite && duration > 0 ? duration : 0.0
    }
    
    func getPosition() -> Float {
        let duration = getDuration()
        let currentTime = getCurrentTime()
        
        if duration > 0 {
            let position = Float(currentTime / duration)
            return min(max(position, 0.0), 1.0)
        }
        
        return 0.0
    }
    
    func getPlayerState() -> String {
        guard let item = playerItem else { return "No Item" }
        
        switch item.status {
        case .unknown: return "Unknown"
        case .readyToPlay: return player.rate > 0 ? "Playing" : "Paused"
        case .failed: return "Failed"
        @unknown default: return "Unknown State"
        }
    }
    
    func setMetadataDuration(_ duration: TimeInterval) {
        metadataDuration = duration
        os_log(.info, log: logger, "🎵 Metadata duration set: %.0f seconds", duration)
    }
    
    // MARK: - Cleanup
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        if let oldItem = playerItem {
            oldItem.removeObserver(self, forKeyPath: "status")
            oldItem.removeObserver(self, forKeyPath: "loadedTimeRanges")
        }
        
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        
        stop()
        os_log(.info, log: logger, "AudioPlayer deinitialized")
    }
}
