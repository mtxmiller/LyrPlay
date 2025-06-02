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
    weak var slimClient: SlimProtoClient?

    
    // *** Track metadata ***
    private var currentTrackTitle: String = "LMS Stream"
    private var currentArtist: String = "Unknown Artist"
    private var currentAlbum: String = "Lyrion Music Server"
    private var currentArtwork: UIImage?
    private var metadataDuration: TimeInterval = 0.0
    
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
        // *** ENHANCED: More frequent updates for better progress display ***
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC)) // 4 times per second
        
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updatePlaybackTime(time)
        }
        
        os_log(.info, log: logger, "✅ Enhanced time observer configured (0.25s intervals)")
    }
    
    private func updatePlaybackTime(_ time: CMTime) {
        let timeInSeconds = CMTimeGetSeconds(time)
        
        // Only update if we have a valid time
        guard timeInSeconds.isFinite && timeInSeconds >= 0 else { return }
        
        // *** ENHANCED: Update now playing info more frequently ***
        updateNowPlayingInfo(isPlaying: player.rate > 0)
        
        // Check for track end (keep your existing logic)
        if let item = playerItem,
           item.status == .readyToPlay,
           metadataDuration > 0 {  // *** Use metadata duration instead of player duration ***
            
            let remainingTime = metadataDuration - timeInSeconds
            
            // Track ending soon or has ended
            if remainingTime <= 1.0 && !isIntentionallyPaused && !isIntentionallyStopped {
                os_log(.info, log: logger, "🎵 Track ending (%.1f seconds remaining)", remainingTime)
                
                // Only trigger once
                if remainingTime <= 0.5 && lastReportedTime > 0 {
                    os_log(.info, log: logger, "🎵 Track ended - triggering callback")
                    onTrackEnded?()
                    lastReportedTime = 0 // Prevent multiple triggers
                    return
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
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentTrackTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentArtist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentAlbum
        
        // Add artwork if available
        if let artwork = currentArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                return artwork
            }
        }
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // *** DISABLE ALL CONTROLS FIRST ***
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.stopCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
        commandCenter.seekForwardCommand.isEnabled = false
        commandCenter.seekBackwardCommand.isEnabled = false
        
        // *** REMOVE ALL EXISTING TARGETS ***
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.stopCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)
        
        // *** ENABLE ONLY THE CONTROLS WE WANT ***
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        
        // *** ADD HANDLERS FOR ENABLED CONTROLS ***
        commandCenter.playCommand.addTarget { [weak self] _ in
            os_log(.info, log: self?.logger ?? OSLog.disabled, "🎵 Lock Screen PLAY command received")
            self?.play()
            self?.slimClient?.sendLockScreenCommand("play")
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            os_log(.info, log: self?.logger ?? OSLog.disabled, "⏸️ Lock Screen PAUSE command received")
            self?.pause()
            self?.slimClient?.sendLockScreenCommand("pause")
            return .success
        }
        
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            os_log(.info, log: self?.logger ?? OSLog.disabled, "⏭️ Lock Screen NEXT TRACK command received")
            self?.slimClient?.sendLockScreenCommand("next")
            return .success
        }
        
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            os_log(.info, log: self?.logger ?? OSLog.disabled, "⏮️ Lock Screen PREVIOUS TRACK command received")
            self?.slimClient?.sendLockScreenCommand("previous")
            return .success
        }
        
        os_log(.info, log: logger, "✅ Remote Command Center configured with track skip controls only")
    }


    
    // *** NEW: Update track metadata ***
    func updateTrackMetadata(title: String, artist: String, album: String, artworkURL: String? = nil, duration: TimeInterval = 0.0) {
        os_log(.info, log: logger, "🎵 Updating track metadata: %{public}s - %{public}s (%.0f sec)", title, artist, duration)
        
        currentTrackTitle = title
        currentArtist = artist
        currentAlbum = album
        metadataDuration = duration  // *** NEW: Store the duration ***
        
        // Load artwork if URL provided
        if let artworkURL = artworkURL, let url = URL(string: artworkURL) {
            loadArtwork(from: url)
        } else {
            currentArtwork = nil
            setupNowPlayingInfo() // Update immediately without artwork
        }
    }
    
    private func loadArtwork(from url: URL) {
        os_log(.info, log: logger, "🖼️ Loading artwork from: %{public}s", url.absoluteString)
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self?.logger ?? OSLog.disabled, "❌ Failed to load artwork: %{public}s", error.localizedDescription)
                    self?.currentArtwork = nil
                } else if let data = data, let image = UIImage(data: data) {
                    os_log(.info, log: self?.logger ?? OSLog.disabled, "✅ Artwork loaded successfully")
                    self?.currentArtwork = image
                } else {
                    os_log(.error, log: self?.logger ?? OSLog.disabled, "❌ Invalid artwork data")
                    self?.currentArtwork = nil
                }
                
                // Update now playing info with or without artwork
                self?.setupNowPlayingInfo()
            }
        }.resume()
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
    
    func playStreamWithFormat(urlString: String, format: String) {
        switch format.uppercased() {
        case "ALAC", "FLAC":
            playStreamWithLosslessOptimizations(urlString: urlString)
        case "AAC":
            playStreamWithAACOptimizations(urlString: urlString)
        case "MP3":
            playStreamWithMP3Optimizations(urlString: urlString)
        default:
            // Unknown format, use your existing method
            os_log(.info, log: logger, "🎵 Unknown format %{public}s, using standard playback", format)
            playStream(urlString: urlString)
        }
    }
    
    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String) {
        playStreamWithFormat(urlString: urlString, format: format)
        
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
    
    private func playStreamWithLosslessOptimizations(urlString: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Starting LOSSLESS stream with optimizations: %{public}s", urlString)
        
        // Use your existing lossless audio session setup
        setupLosslessAudioSession()
        
        // Reset state (keep your existing code)
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        timeStuckCount = 0
        
        // Clean up old observers first (keep your existing code)
        if let oldItem = playerItem {
            oldItem.removeObserver(self, forKeyPath: "status")
            oldItem.removeObserver(self, forKeyPath: "loadedTimeRanges")
        }
        
        // Create new player item with lossless optimizations
        playerItem = AVPlayerItem(url: url)
        
        if let item = playerItem {
            // Enhanced buffering for lossless content
            item.preferredForwardBufferDuration = 15.0  // Longer buffer for lossless
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            item.preferredPeakBitRate = 0  // No bitrate limit - use original quality
            
            os_log(.info, log: logger, "🎵 Configured AVPlayerItem for LOSSLESS streaming")
        }
        
        // Add KVO observers (keep your existing code)
        playerItem?.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        playerItem?.addObserver(self, forKeyPath: "loadedTimeRanges", options: [.new], context: nil)
        
        // Replace current item
        player.replaceCurrentItem(with: playerItem)
        
        // Longer delay for lossless content
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.player.play()
            os_log(.info, log: self.logger, "🎵 Lossless playback started - AVPlayer.rate: %.2f", self.player.rate)
        }
        
        updateNowPlayingInfo(isPlaying: true)
    }
    
    private func playStreamWithAACOptimizations(urlString: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Starting AAC stream with optimizations: %{public}s", urlString)
        
        setupCompressedAudioSession()
        
        // Reset state
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        timeStuckCount = 0
        
        // Clean up old observers
        if let oldItem = playerItem {
            oldItem.removeObserver(self, forKeyPath: "status")
            oldItem.removeObserver(self, forKeyPath: "loadedTimeRanges")
        }
        
        playerItem = AVPlayerItem(url: url)
        
        if let item = playerItem {
            // AAC-specific optimizations
            item.preferredForwardBufferDuration = 8.0   // Good balance for AAC
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            item.preferredPeakBitRate = Double(320 * 1024) // 320kbps max for AAC
            
            os_log(.info, log: logger, "🎵 Configured AVPlayerItem for AAC streaming")
        }
        
        playerItem?.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        playerItem?.addObserver(self, forKeyPath: "loadedTimeRanges", options: [.new], context: nil)
        
        player.replaceCurrentItem(with: playerItem)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.player.play()
            os_log(.info, log: self.logger, "🎵 AAC playback started")
        }
        
        updateNowPlayingInfo(isPlaying: true)
    }
    
    private func playStreamWithMP3Optimizations(urlString: String) {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "Invalid URL: %{public}s", urlString)
            return
        }
        
        os_log(.info, log: logger, "🎵 Starting MP3 stream: %{public}s", urlString)
        
        setupCompressedAudioSession()
        
        // Reset state
        isIntentionallyPaused = false
        isIntentionallyStopped = false
        lastReportedTime = 0
        timeStuckCount = 0
        
        // Clean up old observers
        if let oldItem = playerItem {
            oldItem.removeObserver(self, forKeyPath: "status")
            oldItem.removeObserver(self, forKeyPath: "loadedTimeRanges")
        }
        
        playerItem = AVPlayerItem(url: url)
        
        if let item = playerItem {
            // MP3 live stream optimizations
            item.preferredForwardBufferDuration = 10.0  // Longer buffer for live streams
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            item.preferredPeakBitRate = 0  // No limit for live streams
            
            // *** CRITICAL: Configure for live streaming ***
            if #available(iOS 10.0, *) {
                item.automaticallyPreservesTimeOffsetFromLive = false
            }
            
            os_log(.info, log: logger, "🎵 Configured AVPlayerItem for MP3 live streaming")
        }
        
        playerItem?.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        playerItem?.addObserver(self, forKeyPath: "loadedTimeRanges", options: [.new], context: nil)
        
        player.replaceCurrentItem(with: playerItem)
        
        // *** MORE AGGRESSIVE: Try to play immediately ***
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            os_log(.info, log: self.logger, "🎵 Attempting to start MP3 live stream playback")
            self.player.play()
            self.logDetailedPlayerState()
        }
        
        updateNowPlayingInfo(isPlaying: true)
    }
    
    private func setupLosslessAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            let currentCategory = audioSession.category
            let currentOptions = audioSession.categoryOptions
            
            let desiredOptions: AVAudioSession.CategoryOptions = [
                .allowBluetooth,
                .allowAirPlay,
                .allowBluetoothA2DP,
                .defaultToSpeaker
            ]
            
            // Only change if different
            if currentCategory != .playback || currentOptions != desiredOptions {
                try audioSession.setCategory(
                    .playback,
                    mode: .default,
                    options: desiredOptions
                )
                os_log(.info, log: logger, "🔧 Updated audio session for lossless")
            }
            
            // Only set sample rate if different
            if audioSession.preferredSampleRate != 48000.0 {
                try audioSession.setPreferredSampleRate(48000.0)
                os_log(.info, log: logger, "🔧 Updated sample rate to 48000 Hz")
            }
            
            // Only set buffer duration if different
            if audioSession.preferredIOBufferDuration != 0.015 {
                try audioSession.setPreferredIOBufferDuration(0.015)
                os_log(.info, log: logger, "🔧 Updated buffer duration to 15ms")
            }
            
            if !audioSession.isOtherAudioPlaying {
                try audioSession.setActive(true)
                os_log(.info, log: logger, "🔧 Activated audio session")
            }
            
            os_log(.info, log: logger, "✅ Lossless audio session configured successfully")
        } catch {
            os_log(.error, log: logger, "⚠️ Audio session setup warning: %{public}s (continuing anyway)", error.localizedDescription)
        }
    }
    
    private func setupCompressedAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Check if we need to change the configuration
            // Only reconfigure if it's different from current setup
            let currentCategory = audioSession.category
            let currentOptions = audioSession.categoryOptions
            
            let desiredOptions: AVAudioSession.CategoryOptions = [
                .allowBluetooth,
                .allowAirPlay,
                .allowBluetoothA2DP
            ]
            
            // Only change if different
            if currentCategory != .playback || currentOptions != desiredOptions {
                try audioSession.setCategory(
                    .playback,
                    mode: .default,
                    options: desiredOptions
                )
                
                os_log(.info, log: logger, "🔧 Updated audio session category for compressed audio")
            }
            
            // Only set sample rate if it's different
            if audioSession.preferredSampleRate != 44100.0 {
                try audioSession.setPreferredSampleRate(44100.0)  // CD quality
                os_log(.info, log: logger, "🔧 Updated sample rate to 44100 Hz")
            }
            
            // Only set buffer duration if it's different
            if audioSession.preferredIOBufferDuration != 0.02 {
                try audioSession.setPreferredIOBufferDuration(0.02)  // 20ms buffer
                os_log(.info, log: logger, "🔧 Updated buffer duration to 20ms")
            }
            
            // Only activate if not already active
            if !audioSession.isOtherAudioPlaying {
                try audioSession.setActive(true)
                os_log(.info, log: logger, "🔧 Activated audio session")
            }
            
            os_log(.info, log: logger, "✅ Compressed audio session configured successfully")
        } catch {
            // Don't treat this as fatal - log the error but continue
            os_log(.error, log: logger, "⚠️ Audio session setup warning: %{public}s (continuing anyway)", error.localizedDescription)
        }
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
                    os_log(.info, log: logger, "🎵 Duration: Invalid or infinite (live stream detected)")
                    
                    // *** FIX: Auto-start playback for live streams ***
                    DispatchQueue.main.async {
                        if self.player.rate == 0 {
                            os_log(.info, log: self.logger, "🎵 Auto-starting live stream playback")
                            self.player.play()
                            
                            // Log player state after starting
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                self.logDetailedPlayerState()
                            }
                        }
                    }
                }
                
                // *** FIXED: Log audio format information ***
                logAudioFormatInfo(for: item)
                
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
                
                // *** FIX: Start playback when we have enough buffer for live streams ***
                if loadedDuration > 2.0 && self.player.rate == 0 && !self.isIntentionallyPaused {
                    os_log(.info, log: logger, "🎵 Sufficient buffer loaded, starting playback")
                    DispatchQueue.main.async {
                        self.player.play()
                        self.logDetailedPlayerState()
                    }
                }
            } else {
                os_log(.info, log: logger, "🎵 No loaded time ranges yet")
            }
        } else {
            // Call super for any unhandled KVO
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    private func logAudioFormatInfo(for item: AVPlayerItem) {
        // Use the asset tracks instead of playerItem tracks
        guard let asset = item.asset as? AVURLAsset else {
            os_log(.info, log: logger, "🎵 No asset available for format detection")
            return
        }
        
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            os_log(.info, log: logger, "🎵 No audio tracks found")
            return
        }
        
        if let formatDescriptions = audioTrack.formatDescriptions as? [CMAudioFormatDescription],
           let formatDescription = formatDescriptions.first {
            
            if let audioFormat = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) {
                let format = audioFormat.pointee
                let sampleRate = format.mSampleRate
                let channels = format.mChannelsPerFrame
                let bitsPerChannel = format.mBitsPerChannel
                let formatID = format.mFormatID
                
                let formatName = formatIDToString(formatID)
                
                os_log(.info, log: logger, "🎵 Audio Format: %{public}s, %.0f Hz, %d ch, %d bits",
                       formatName, sampleRate, channels, bitsPerChannel)
            }
        }
    }
    
    private func formatIDToString(_ formatID: AudioFormatID) -> String {
        let chars = [
            UInt8((formatID >> 24) & 0xFF),
            UInt8((formatID >> 16) & 0xFF),
            UInt8((formatID >> 8) & 0xFF),
            UInt8(formatID & 0xFF)
        ]
        
        // Check for common lossless formats
        switch formatID {
        case kAudioFormatAppleLossless:
            return "ALAC (Apple Lossless)"
        case kAudioFormatFLAC:
            return "FLAC"
        case kAudioFormatMPEG4AAC:
            return "AAC"
        case kAudioFormatMPEGLayer3:
            return "MP3"
        case kAudioFormatLinearPCM:
            return "PCM"
        default:
            if let string = String(bytes: chars, encoding: .ascii) {
                return "'\(string)'"
            } else {
                return "Unknown (\(formatID))"
            }
        }
    }

    
    // Add this new method to get detailed player state:
    private func logDetailedPlayerState() {
        os_log(.info, log: logger, "🔍 DETAILED PLAYER STATE:")
        os_log(.info, log: logger, "🔍 Player rate: %.3f", player.rate)
        os_log(.info, log: logger, "🔍 Player status: %{public}s", avPlayerStatusDescription(player.status))
        os_log(.info, log: logger, "🔍 Player timeControlStatus: %{public}s", timeControlStatusDescription(player.timeControlStatus))
        
        if let item = playerItem {
            os_log(.info, log: logger, "🔍 Item status: %{public}s", avPlayerItemStatusDescription(item.status))
            os_log(.info, log: logger, "🔍 Item isPlaybackLikelyToKeepUp: %{public}s", item.isPlaybackLikelyToKeepUp ? "YES" : "NO")
            os_log(.info, log: logger, "🔍 Item isPlaybackBufferEmpty: %{public}s", item.isPlaybackBufferEmpty ? "YES" : "NO")
            os_log(.info, log: logger, "🔍 Item isPlaybackBufferFull: %{public}s", item.isPlaybackBufferFull ? "YES" : "NO")
            
            let currentTime = CMTimeGetSeconds(player.currentTime())
            os_log(.info, log: logger, "🔍 Current time: %.3f seconds", currentTime)
            
            // Check if we have any errors
            if let error = item.error {
                os_log(.error, log: logger, "🔍 Item error: %{public}s", error.localizedDescription)
            }
            
            // Check loaded time ranges
            let loadedRanges = item.loadedTimeRanges
            for (index, range) in loadedRanges.enumerated() {
                let timeRange = range.timeRangeValue
                let start = CMTimeGetSeconds(timeRange.start)
                let duration = CMTimeGetSeconds(timeRange.duration)
                os_log(.info, log: logger, "🔍 Loaded range %d: %.2f - %.2f (%.2f sec)", index, start, start + duration, duration)
            }
        }
    }
    
    private func timeControlStatusDescription(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused:
            return "Paused"
        case .playing:
            return "Playing"
        case .waitingToPlayAtSpecifiedRate:
            return "Waiting to Play"
        @unknown default:
            return "Unknown"
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
        
        // *** ENHANCED: Use metadata duration for progress display ***
        if metadataDuration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = metadataDuration
            os_log(.debug, log: logger, "🔍 Setting playback duration to %.0f seconds from metadata", metadataDuration)
        } else {
            // Fallback: try to get duration from player item
            if let item = playerItem, item.duration.isValid {
                let duration = CMTimeGetSeconds(item.duration)
                if duration.isFinite && duration > 0 {
                    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
                    os_log(.debug, log: logger, "🔍 Setting playback duration to %.0f seconds from player", duration)
                } else {
                    // For live streams, estimate based on current time if we have substantial playback
                    let currentTime = getCurrentTime()
                    if currentTime > 30 { // If we've been playing for more than 30 seconds
                        // Don't set duration - let iOS handle it as a live stream
                        nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
                        os_log(.debug, log: logger, "🔍 Live stream detected - removing duration info")
                    }
                }
            }
        }
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
        
        // *** DEBUG: Log what we're setting ***
        if let duration = nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? TimeInterval {
            let currentTime = nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval ?? 0
            os_log(.debug, log: logger, "🔍 Now Playing: %.0f/%.0f seconds, rate: %.1f",
                   currentTime, duration, isPlaying ? 1.0 : 0.0)
        }
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
            return min(max(position, 0.0), 1.0) // Clamp between 0 and 1
        }
        
        return 0.0
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
