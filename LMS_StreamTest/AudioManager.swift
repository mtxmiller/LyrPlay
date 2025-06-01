import Foundation
import AVFoundation
import MediaPlayer
import os.log

class AudioManager: NSObject, ObservableObject {
    private var player: AVPlayer!
    private var playerItem: AVPlayerItem?
    
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioManager")
    private var lastReportedTime: Double = 0
    private var timeStuckCount = 0
    
    // *** Track intentional pause state ***
    private var isIntentionallyPaused = false
    private var isIntentionallyStopped = false
    
    // *** Background management ***
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var timeObserver: Any?
    
    // Callback for when track ends
    var onTrackEnded: (() -> Void)?
    
    override init() {
        super.init()
        setupAVPlayer()
        setupAudioSession()
        setupBackgroundObservers()
    }
    
    private func setupAVPlayer() {
        // Create AVPlayer - native iOS player with proper background support
        player = AVPlayer()
        
        // Configure for background playback
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = true
        
        os_log(.info, log: logger, "✅ AVPlayer initialized")
        
        setupTimeObserver()
        setupPlayerItemObservers()
        setupNowPlayingInfo()
        setupRemoteCommandCenter()
    }
    
    private func setupPlayerItemObservers() {
        // Observe player item status changes more comprehensively
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
    
    private func setupTimeObserver() {
        // Observe playback time every 0.5 seconds
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updatePlaybackTime(time)
        }
        
        os_log(.info, log: logger, "✅ Time observer configured")
    }
    
    private func updatePlaybackTime(_ time: CMTime) {
        let timeInSeconds = CMTimeGetSeconds(time)
        
        // Update now playing info
        updateNowPlayingInfo(isPlaying: player.rate > 0)
        
        // Check for track end
        if let item = playerItem,
           item.status == .readyToPlay,
           let duration = item.duration.isValid ? item.duration : nil {
            
            let durationSeconds = CMTimeGetSeconds(duration)
            let remainingTime = durationSeconds - timeInSeconds
            
            // Track ending soon or has ended
            if remainingTime <= 1.0 && !isIntentionallyPaused && !isIntentionallyStopped {
                os_log(.info, log: logger, "🎵 Track ending (%.1f seconds remaining)", remainingTime)
                
                // Only trigger once
                if remainingTime <= 0.5 && lastReportedTime > 0 {
                    os_log(.info, log: logger, "🎵 Track ended - triggering callback")
                    onTrackEnded?()
                    lastReportedTime = 0 // Prevent multiple triggers
                }
            }
        }
        
        if timeInSeconds >= 0 {
            lastReportedTime = timeInSeconds
        }
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // *** NATIVE iOS BACKGROUND AUDIO CONFIGURATION ***
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetooth, .allowAirPlay]
            )
            try audioSession.setActive(true)
            
            os_log(.info, log: logger, "✅ Native audio session configured")
        } catch {
            os_log(.error, log: logger, "❌ Failed to setup audio session: %{public}s", error.localizedDescription)
        }
    }
    
    private func setupBackgroundObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // Observe player item status changes
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
        
        os_log(.info, log: logger, "✅ Background observers configured")
    }
    
    @objc private func appDidEnterBackground() {
        os_log(.info, log: logger, "📱 App entering background")
        startBackgroundTask()
    }
    
    @objc private func appWillEnterForeground() {
        os_log(.info, log: logger, "📱 App entering foreground")
        stopBackgroundTask()
    }
    
    @objc private func playerItemDidReachEnd() {
        os_log(.info, log: logger, "🎵 AVPlayer item reached end")
        
        if !isIntentionallyPaused && !isIntentionallyStopped {
            os_log(.info, log: logger, "🎵 Natural track end - triggering callback")
            DispatchQueue.main.async {
                self.onTrackEnded?()
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
    }
    
    private func startBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AVPlayerBackgroundPlayback") {
            os_log(.error, log: self.logger, "⏰ Background task expiring")
            self.stopBackgroundTask()
        }
        os_log(.info, log: logger, "🎯 Background task started")
    }
    
    private func stopBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    
    private func setupNowPlayingInfo() {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = "LMS Stream"
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Unknown Artist"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Lyrion Music Server"
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = true
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        
        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.stop()
            return .success
        }
    }
    
    // *** NATIVE AVPLAYER STREAMING ***
    func playStream(urlString: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Playing stream with AVPlayer: %{public}s", urlString)
        
        // *** TEST URL ACCESSIBILITY FIRST ***
        testURLAccessibility(url: url)
        
        // Reset state
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        timeStuckCount = 0
        
        // *** CLEAN UP OLD OBSERVERS FIRST ***
        if let oldItem = playerItem {
            oldItem.removeObserver(self, forKeyPath: "status")
            oldItem.removeObserver(self, forKeyPath: "loadedTimeRanges")
        }
        
        // Create new player item
        playerItem = AVPlayerItem(url: url)
        
        // *** ADD KVO OBSERVERS FOR DEBUGGING ***
        playerItem?.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        playerItem?.addObserver(self, forKeyPath: "loadedTimeRanges", options: [.new], context: nil)
        
        os_log(.info, log: logger, "🔍 Added KVO observers to new AVPlayerItem")
        
        // Replace current item
        player.replaceCurrentItem(with: playerItem)
        
        // *** WAIT A MOMENT BEFORE PLAYING TO LET ITEM LOAD ***
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Start playback
            self.player.play()
            
            // *** LOG STATE AFTER BRIEF DELAY ***
            os_log(.info, log: self.logger, "🎵 After delay - AVPlayer.rate: %.2f", self.player.rate)
            os_log(.info, log: self.logger, "🎵 After delay - AVPlayer.status: %{public}s", self.avPlayerStatusDescription(self.player.status))
            
            if let item = self.playerItem {
                os_log(.info, log: self.logger, "🎵 After delay - AVPlayerItem.status: %{public}s", self.avPlayerItemStatusDescription(item.status))
            }
        }
        
        updateNowPlayingInfo(isPlaying: true)
        
        os_log(.info, log: logger, "✅ AVPlayer stream started")
    }
    
    private func testURLAccessibility(url: URL) {
        // Quick test to see if the URL is accessible
        os_log(.info, log: logger, "🌐 Testing URL accessibility: %{public}s", url.absoluteString)
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD" // Just check headers, don't download content
        request.timeoutInterval = 10
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self.logger, "❌ URL test failed: %{public}s", error.localizedDescription)
                } else if let httpResponse = response as? HTTPURLResponse {
                    let contentType = httpResponse.allHeaderFields["Content-Type"] as? String ?? "unknown"
                    let contentLength = httpResponse.allHeaderFields["Content-Length"] as? String ?? "unknown"
                    
                    os_log(.info, log: self.logger, "✅ URL test - HTTP %d, Content-Type: %{public}s, Length: %{public}s",
                           httpResponse.statusCode, contentType, contentLength)
                    
                    // Check if it's actually an audio stream
                    if contentType.contains("audio") {
                        os_log(.info, log: self.logger, "🎵 Confirmed: Server is returning audio content")
                    } else {
                        os_log(.error, log: self.logger, "⚠️ Warning: Server not returning audio content")
                    }
                } else {
                    os_log(.error, log: self.logger, "⚠️ Unknown response type")
                }
            }
        }
        task.resume()
    }
    
    private func avPlayerItemStatusDescription(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "Unknown"
        case .readyToPlay: return "Ready to Play"
        case .failed: return "Failed"
        @unknown default: return "Unknown Status"
        }
    }
    
    // *** KVO OBSERVER FOR DEBUGGING ***
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        os_log(.info, log: logger, "🔍 KVO triggered for keyPath: %{public}s", keyPath ?? "nil")
        
        if keyPath == "status", let item = object as? AVPlayerItem {
            switch item.status {
            case .unknown:
                os_log(.info, log: logger, "🎵 AVPlayerItem status: Unknown")
            case .readyToPlay:
                os_log(.info, log: logger, "🎵 AVPlayerItem status: Ready to Play")
                let duration = CMTimeGetSeconds(item.duration)
                if duration.isFinite && duration > 0 {
                    os_log(.info, log: logger, "🎵 Duration: %.2f seconds", duration)
                } else {
                    os_log(.info, log: logger, "🎵 Duration: Invalid or infinite")
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
        } else if keyPath == "loadedTimeRanges", let item = object as? AVPlayerItem {
            let loadedRanges = item.loadedTimeRanges
            if !loadedRanges.isEmpty {
                let timeRange = loadedRanges[0].timeRangeValue
                let loadedDuration = CMTimeGetSeconds(timeRange.duration)
                os_log(.info, log: logger, "🎵 Loaded time range: %.2f seconds", loadedDuration)
            } else {
                os_log(.info, log: logger, "🎵 No loaded time ranges yet")
            }
        } else {
            // Call super for any unhandled KVO
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func avPlayerStatusDescription(_ status: AVPlayer.Status) -> String {
        switch status {
        case .unknown: return "Unknown"
        case .readyToPlay: return "Ready to Play"
        case .failed: return "Failed"
        @unknown default: return "Unknown Status"
        }
    }
    
    func playStreamAtPosition(urlString: String, startTime: Double) {
        playStream(urlString: urlString)
        
        if startTime > 0 {
            let seekTime = CMTime(seconds: startTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            
            player.seek(to: seekTime) { [weak self] finished in
                if finished {
                    self?.lastReportedTime = startTime
                    os_log(.info, log: self?.logger ?? OSLog.disabled, "🔄 Seeked to position: %.2f seconds", startTime)
                }
            }
        }
    }
    
    func play() {
        isIntentionallyPaused = false
        player.play()
        updateNowPlayingInfo(isPlaying: true)
        os_log(.info, log: logger, "▶️ Resumed playback")
    }
    
    func pause() {
        isIntentionallyPaused = true
        player.pause()
        updateNowPlayingInfo(isPlaying: false)
        os_log(.info, log: logger, "⏸️ Paused playback")
    }
    
    func stop() {
        isIntentionallyStopped = true
        isIntentionallyPaused = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        updateNowPlayingInfo(isPlaying: false)
        os_log(.info, log: logger, "⏹️ Stopped playback")
    }
    
    func getCurrentTime() -> Double {
        let time = player.currentTime()
        return CMTimeGetSeconds(time)
    }
    
    func checkIfTrackEnded() -> Bool {
        guard let item = playerItem else { return false }
        
        let currentTime = CMTimeGetSeconds(player.currentTime())
        let duration = CMTimeGetSeconds(item.duration)
        
        // Track ended if we're at the end and not intentionally paused/stopped
        if currentTime >= duration - 0.5 && !isIntentionallyPaused && !isIntentionallyStopped {
            return true
        }
        
        return false
    }
    
    private func updateNowPlayingInfo(isPlaying: Bool) {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = getCurrentTime()
        
        // Get duration if available
        if let item = playerItem, item.duration.isValid {
            let duration = CMTimeGetSeconds(item.duration)
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        }
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
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
    
    func getDuration() -> Double {
        guard let item = playerItem, item.duration.isValid else { return 0.0 }
        return CMTimeGetSeconds(item.duration)
    }
    
    func getPosition() -> Float {
        let duration = getDuration()
        let currentTime = getCurrentTime()
        
        return duration > 0 ? Float(currentTime / duration) : 0.0
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopBackgroundTask()
        
        // Remove KVO observers
        playerItem?.removeObserver(self, forKeyPath: "status")
        playerItem?.removeObserver(self, forKeyPath: "loadedTimeRanges")
        
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        
        stop()
    }
}
