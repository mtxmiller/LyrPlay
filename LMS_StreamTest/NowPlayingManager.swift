// File: NowPlayingManager.swift
// Enhanced to use server time as primary source for lock screen accuracy
import Foundation
import Combine
import MediaPlayer
import UIKit
import os.log

class NowPlayingManager: ObservableObject {

    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "NowPlayingManager")

    // MARK: - Track Metadata
    @Published private(set) var currentTrackTitle: String = "LyrPlay"
    @Published private(set) var currentArtist: String = "Unknown Artist"
    @Published private(set) var currentAlbum: String = "Lyrion Music Server"
    @Published private(set) var currentArtwork: UIImage?
    @Published private(set) var metadataDuration: TimeInterval = 0.0
    @Published private(set) var hasTrackLoaded: Bool = false

    // MARK: - Time Sources
    private weak var audioManager: AudioManager?
    private var lastKnownServerTime: Double = 0.0
    private var lastKnownAudioTime: Double = 0.0
    private var isUsingServerTime: Bool = false

    // MARK: - Deduplication State (prevent flooding MPNowPlayingInfoCenter)
    private var lastUpdatedTime: Double = -1.0

    // MARK: - Track Generation Guard (last-write-wins across the two async hops)
    //
    // A track change applies text (title/artist/album) synchronously, then kicks
    // off a SECOND async hop to download the cover. Without a shared guard, an
    // older fetch's response or a slower cover download can land after a newer
    // one and overwrite the correct data — and worse, text and cover can end up
    // pointing at DIFFERENT tracks. This is the intermittent "synced player shows
    // the wrong/stale cover, then self-heals next track" bug.
    //
    //   updateTrackMetadata(B)  → bump generation to N, paint text(B)
    //     └─ loadArtwork(B, gen=N) ── async download ──┐
    //   updateTrackMetadata(C)  → bump generation to N+1, paint text(C)
    //     └─ loadArtwork(C, gen=N+1) ─ async download ─┤
    //                                                  ▼
    //   applyArtwork(imageB, gen=N)  → N != N+1 → DROP (stale, never paints)
    //   applyArtwork(imageC, gen=N+1)→ match     → paints
    //
    // Every mutation of currentArtwork goes through applyArtwork(_:forGeneration:)
    // so text and cover can never desync. All reads/writes happen on the main
    // thread (updateTrackMetadata is called on main; loadArtwork's completion
    // hops to main before calling applyArtwork), so a plain Int is sufficient.
    private var trackGeneration: Int = 0
    private var artworkTask: URLSessionDataTask?

    #if DEBUG
    /// Test-only read access to the current track generation so unit tests can
    /// assert the last-write-wins artwork guard without driving real downloads.
    var currentTrackGenerationForTesting: Int { trackGeneration }
    #endif

    // Log throttling (only log lock screen updates every 10 seconds)
    private var lastLockScreenLogTime: Date?

    private var lockScreenStoredPosition: Double = 0.0
    private var lockScreenStoredTimestamp: Date?
    private var lockScreenWasPlaying: Bool = false

    // MARK: - Lock Screen Command Reference
    weak var slimClient: SlimProtoCoordinator?
    
    // MARK: - Update Timer
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 1.0

    #if os(tvOS)
    /// Most recently reported playback state — used by the tvOS idle-timer
    /// hook so settings-toggle changes and lifecycle events can re-evaluate
    /// the desired idle-timer state without re-deriving it from elsewhere.
    private var lastReportedIsPlaying: Bool = false
    #endif

    // MARK: - Initialization
    init() {
        setupNowPlayingInfo()
        startUpdateTimer()
        #if os(tvOS)
        registerIdleTimerObservers()
        #endif
        //os_log(.info, log: logger, "Enhanced NowPlayingManager initialized with server time support")
    }
    
    // MARK: - Server Time Integration
    
    func setAudioManager(_ audioManager: AudioManager) {
        self.audioManager = audioManager
        //os_log(.info, log: logger, "✅ Audio manager connected for fallback timing")
    }
    
    // MARK: - Update Timer Management
    private func startUpdateTimer() {
        stopUpdateTimer()
        
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateNowPlayingTime()
        }
        
        //os_log(.debug, log: logger, "🔄 Now playing update timer started")
    }
    
    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private func updateNowPlayingTime() {
        let (currentTime, isPlaying, timeSource) = getCurrentPlaybackInfo()

        // Update now playing info with current time (no throttling)
        updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)

        // Save last updated value (for other logic)
        lastUpdatedTime = currentTime

        // Throttle logging to every 10 seconds to reduce spam
        let shouldLog: Bool
        if let lastLog = lastLockScreenLogTime {
            shouldLog = Date().timeIntervalSince(lastLog) >= 10.0
        } else {
            shouldLog = true
        }

        // UNIFIED RECOVERY (LMS_StreamTest-6lb): Save position for offline recovery
        // This timer runs continuously (never stopped), so position is saved even when
        // disconnected from server. Uses the same interpolated time shown on lock screen.
        if isPlaying && currentTime > 0 {
            UserDefaults.standard.set(currentTime, forKey: "lyrplay_recovery_position")
            // Debug: Log position saves (throttled)
            if shouldLog {
                os_log(.info, log: logger, "💾 RECOVERY SAVE: %.2f seconds (source: %{public}s)", currentTime, "\(timeSource)")
            }
        } else if shouldLog {
            // Debug: Log why we're NOT saving
            os_log(.info, log: logger, "⚠️ NOT SAVING: isPlaying=%{public}s currentTime=%.2f", isPlaying ? "YES" : "NO", currentTime)
        }

        if shouldLog {
            os_log(.info, log: logger, "🔒 LOCK SCREEN: time=%.2f playing=%{public}s source=%{public}s",
                   currentTime, isPlaying ? "YES" : "NO", "\(timeSource)")
            lastLockScreenLogTime = Date()
        }

        // REMOVED: Server-time based track end detection - now using BASS_SYNC_END exclusively
        // The duplicate detection was causing spurious STMd signals during track transitions

        // Log time source changes
        let newUsingServerTime = (timeSource == .serverTime)
        if newUsingServerTime != isUsingServerTime {
            isUsingServerTime = newUsingServerTime
            os_log(.info, log: logger, "🔒 TIME SOURCE CHANGED: %{public}s → %{public}s",
                   isUsingServerTime ? "Server" : "Other", timeSource.description)
        }
    }
    
    // MARK: - Time Source Management
    private enum TimeSource {
        case serverTime
        case audioManager
        case lastKnown
        
        var description: String {
            switch self {
            case .serverTime: return "Server Time"
            case .audioManager: return "Audio Manager"
            case .lastKnown: return "Last Known"
            }
        }
    }
    
    private func getCurrentPlaybackInfo() -> (time: Double, isPlaying: Bool, source: TimeSource) {
        
        // CRITICAL FIX: If we have a stored recovery position, use it during disconnection periods
        if let storedTimestamp = lockScreenStoredTimestamp {
            let timeSinceStorage = Date().timeIntervalSince(storedTimestamp)
            
            // If we stored a position recently (within 2 minutes) and we're disconnected, use stored position
            if timeSinceStorage < 120.0 && lockScreenStoredPosition > 0.1 {
                let recoveryInfo = getStoredPositionWithTimeOffset()
                if recoveryInfo.isValid {
                    return (time: recoveryInfo.position, isPlaying: recoveryInfo.wasPlaying, source: .lastKnown)
                }
            }
        }
        
        // SIMPLIFIED: Use SlimProto time from coordinator if available
        if let slimClient = slimClient {
            let (slimProtoTime, isPlaying) = slimClient.getCurrentInterpolatedTime()

            if slimProtoTime > 0.0 {
                // Too spammy - uncomment only for debugging time sources
                // os_log(.debug, log: logger, "🔒 Using SlimProto time: %.2f (playing: %{public}s)", slimProtoTime, isPlaying ? "YES" : "NO")
                lastKnownServerTime = slimProtoTime
                return (time: slimProtoTime, isPlaying: isPlaying, source: .serverTime)
            }
        }
        
        // Fall back to last known server time if we have it
        if lastKnownServerTime > 0.1 {
            os_log(.debug, log: logger, "🔒 Using last known server time: %.2f", lastKnownServerTime)
            return (time: lastKnownServerTime, isPlaying: false, source: .serverTime)
        }
        
        // Only fall back to audio player if we have NO SlimProto time at all
        // FIXED: Use dedicated fallback method since AudioManager.getCurrentTime() is deprecated
        if let audioManager = audioManager {
            let audioTime = audioManager.getAudioPlayerTimeForFallback()  // Fallback only
            let isPlaying = audioManager.getPlayerState() == "Playing"

            if audioTime > 0.1 {
                lastKnownAudioTime = audioTime
                os_log(.debug, log: logger, "🔒 FALLBACK: Using AudioPlayer time %.2f (server time unavailable)", audioTime)
                return (time: audioTime, isPlaying: isPlaying, source: .audioManager)
            }
        }
        
        // Ultimate fallback - use the best time we have
        let fallbackTime = max(lastKnownServerTime, lastKnownAudioTime, lockScreenStoredPosition)
        return (time: fallbackTime, isPlaying: false, source: .lastKnown)
    }
    
    // Add this method to get stored position with time adjustment
    func getStoredPositionWithTimeOffset() -> (position: Double, wasPlaying: Bool, isValid: Bool) {
        os_log(.info, log: logger, "🔒 RECOVERY REQUEST STARTED")
        
        // Log what's currently stored
        os_log(.info, log: logger, "🔒 CURRENT STORED VALUES:")
        os_log(.info, log: logger, "  - lockScreenStoredPosition: %.2f", lockScreenStoredPosition)
        os_log(.info, log: logger, "  - lockScreenWasPlaying: %{public}s", lockScreenWasPlaying ? "YES" : "NO")
        os_log(.info, log: logger, "  - lockScreenStoredTimestamp: %{public}s",
               lockScreenStoredTimestamp?.description ?? "nil")
        
        guard let storedTime = lockScreenStoredTimestamp else {
            os_log(.info, log: logger, "🔒 RECOVERY REJECTED - No stored timestamp")
            return (0.0, false, false)
        }
        
        // Only valid if stored recently (within 10 minutes)
        let timeSinceStorage = Date().timeIntervalSince(storedTime)
        guard timeSinceStorage < 600 else {
            os_log(.error, log: logger, "🔒 RECOVERY REJECTED - Position too old: %.0f seconds", timeSinceStorage)
            return (0.0, false, false)
        }
        
        // SIMPLIFIED: Always return the exact stored position - no estimation!
        os_log(.info, log: logger, "🔒 RECOVERY RETURNING:")
        os_log(.info, log: logger, "  - Position: %.2f", lockScreenStoredPosition)
        os_log(.info, log: logger, "  - Was playing: %{public}s", lockScreenWasPlaying ? "YES" : "NO")
        os_log(.info, log: logger, "  - Valid: YES")
        
        return (lockScreenStoredPosition, lockScreenWasPlaying, true)
    }

    // MARK: - Now Playing Info Setup
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
        os_log(.info, log: logger, "✅ Initial now playing info configured")
    }
    
    // MARK: - Track Metadata Management
    func updateTrackMetadata(title: String, artist: String, album: String, artworkURL: String? = nil, duration: TimeInterval? = nil) {
        // Only update duration if explicitly provided (Material skin approach)
        if let duration = duration {
            os_log(.info, log: logger, "🎵 Updating track metadata: %{public}s - %{public}s (%.0f sec)", title, artist, duration)
            metadataDuration = duration
        } else {
            os_log(.info, log: logger, "🎵 Updating track metadata: %{public}s - %{public}s", title, artist)
        }

        currentTrackTitle = title
        currentArtist = artist
        currentAlbum = album
        hasTrackLoaded = true

        // Reset deduplication state so next update goes through immediately
        lastUpdatedTime = -1.0

        // Open a new track generation. Text above is already painted; the cover
        // (a second async hop) is gated on this same generation so text and cover
        // can never end up showing different tracks.
        trackGeneration += 1
        let generation = trackGeneration

        // Load artwork if URL provided
        if let artworkURL = artworkURL, let url = URL(string: artworkURL) {
            loadArtwork(from: url, generation: generation)
        } else {
            // No artwork for this track — clear (guarded so a late stale load
            // can't repaint), then refresh now-playing immediately.
            applyArtwork(nil, forGeneration: generation)
            let (currentTime, isPlaying, _) = getCurrentPlaybackInfo()
            updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
        }
    }

    /// Synchronous last-write-wins apply for cover art. The ONE place
    /// `currentArtwork` is mutated. Returns `true` if applied, `false` if dropped
    /// as stale. Factored out (no network, no async) so the generation guard is
    /// directly unit-testable. Must be called on the main thread.
    @discardableResult
    func applyArtwork(_ image: UIImage?, forGeneration generation: Int) -> Bool {
        guard generation == trackGeneration else {
            os_log(.info, log: logger, "🖼️ Dropping stale artwork (gen %d != current %d)", generation, trackGeneration)
            return false
        }
        currentArtwork = image
        return true
    }

    private func loadArtwork(from url: URL, generation: Int) {
        os_log(.info, log: logger, "🖼️ Loading artwork from: %{public}s (gen %d)", url.absoluteString, generation)

        // Cancel any prior in-flight artwork download. On Apple TV covers can be
        // 2048px; without this, superseded loads still download in full before
        // being dropped by the generation guard. A cancelled task's completion
        // fires with NSURLErrorCancelled and an older generation, so the guard
        // drops it — cancellation never clears the current cover.
        artworkTask?.cancel()

        // Add HTTP Basic Authentication if configured (for password-protected LMS servers)
        var request = URLRequest(url: url)
        if let authHeader = SettingsManager.shared.generateAuthHeader() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                let image: UIImage?
                if let error = error {
                    os_log(.error, log: self.logger, "❌ Failed to load artwork: %{public}s", error.localizedDescription)
                    image = nil
                } else if let data = data, let decoded = UIImage(data: data) {
                    os_log(.info, log: self.logger, "✅ Artwork loaded successfully")
                    image = decoded
                } else {
                    os_log(.error, log: self.logger, "❌ Invalid artwork data")
                    image = nil
                }

                // Apply only if this is still the current track's load. A genuine
                // current-track failure applies `nil` (clear to no-art) so the
                // cover always matches the playing track — never the previous one.
                let applied = self.applyArtwork(image, forGeneration: generation)

                // Refresh now-playing only for the winning load; stale loads
                // must not push an out-of-date now-playing snapshot.
                if applied {
                    let (currentTime, isPlaying, _) = self.getCurrentPlaybackInfo()
                    self.updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
                }
            }
        }
        artworkTask = task
        task.resume()
    }
    
    // MARK: - Now Playing Info Updates
    private func updateNowPlayingInfo(isPlaying: Bool, currentTime: Double = 0.0) {
        //os_log(.debug, log: logger, "🔒 SETTING LOCK SCREEN: %.2f (playing: %{public}s)",
         //      currentTime, isPlaying ? "YES" : "NO")
        
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        
        // Update basic metadata
        nowPlayingInfo[MPMediaItemPropertyTitle] = currentTrackTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = currentArtist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = currentAlbum
        
        // Update playback state
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        
        // Add artwork if available
        if let artwork = currentArtwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                return artwork
            }
        }
        
        // Set duration using metadata duration for progress display
        if metadataDuration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = metadataDuration
        } else {
            // For live streams, remove duration info
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo

        #if os(tvOS)
        reportPlaybackStateForIdleTimer(isPlaying)
        #endif
    }

    // MARK: - Backward Compatibility Methods (keeping existing interface)
    func updatePlaybackState(isPlaying: Bool, currentTime: Double) {
        // SIMPLIFIED: Always update but with throttling
        let timeDifference = abs(currentTime - lastKnownAudioTime)
        
        // Only update if there's a meaningful time change (2+ seconds)
        if timeDifference > 2.0 {
            lastKnownAudioTime = currentTime
            updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)
            os_log(.debug, log: logger, "📍 Updated from audio manager: %.2f (state: %{public}s)",
                   currentTime, isPlaying ? "playing" : "paused")
        }
    }
    
    // MARK: - Simplified SlimProto Integration
    func updateFromSlimProto(currentTime: Double, duration: Double = 0.0, isPlaying: Bool) {
        // This replaces the complex ServerTimeSynchronizer integration

        // CRITICAL FIX: Reset lastKnownServerTime to 0 when playback stops (matches squeezelite behavior)
        // Too spammy - uncomment only for debugging SlimProto updates
        // os_log(.info, log: logger, "🔍 updateFromSlimProto called: time=%.2f, duration=%.2f, playing=%{public}s, lastKnown=%.2f",
        //        currentTime, duration, isPlaying ? "YES" : "NO", lastKnownServerTime)

        if currentTime == 0.0 && !isPlaying {
            lastKnownServerTime = 0.0
            os_log(.info, log: logger, "🔒 Reset lastKnownServerTime to 0.0 (playlist ended)")
        } else {
            lastKnownServerTime = currentTime
        }

        // Update duration if provided
        if duration > 0 {
            metadataDuration = duration
        }

        // Update now playing info immediately with SlimProto data
        updateNowPlayingInfo(isPlaying: isPlaying, currentTime: currentTime)

        // Too spammy - uncomment only for debugging SlimProto updates
        // os_log(.debug, log: logger, "📍 Updated from SlimProto: %.2f (playing: %{public}s)",
        //        currentTime, isPlaying ? "YES" : "NO")
    }
    
    // MARK: - Metadata Access
    func getCurrentTrackTitle() -> String {
        return currentTrackTitle
    }
    
    func getCurrentArtist() -> String {
        return currentArtist
    }

    // MARK: - Lock Screen Integration
    func setSlimClient(_ slimClient: SlimProtoCoordinator) {
        self.slimClient = slimClient
        os_log(.info, log: logger, "✅ SlimProto client reference set for lock screen commands")
    }
    
    // MARK: - Clear Now Playing Info
    func clearNowPlayingInfo() {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        nowPlayingInfoCenter.nowPlayingInfo = nil

        // Open a new generation and cancel any in-flight load so a download that
        // completes after this teardown can't repaint a cover over the cleared state.
        trackGeneration += 1
        artworkTask?.cancel()

        // Reset to defaults
        currentTrackTitle = "LyrPlay"
        currentArtist = "Unknown Artist"
        currentAlbum = "Lyrion Music Server"
        currentArtwork = nil
        metadataDuration = 0.0
        hasTrackLoaded = false
        lastKnownServerTime = 0.0
        lastKnownAudioTime = 0.0
        
        os_log(.info, log: logger, "🗑️ Now playing info cleared")
    }
    
    // MARK: - Remote Command State
    func enableRemoteCommands(_ enable: Bool) {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = enable
        commandCenter.pauseCommand.isEnabled = enable
        commandCenter.nextTrackCommand.isEnabled = enable
        commandCenter.previousTrackCommand.isEnabled = enable

        os_log(.info, log: logger, "🎛️ Remote commands %{public}s", enable ? "enabled" : "disabled")
    }

    // MARK: - Playlist Position State (for CarPlay button states)
    func updatePlaylistPosition(currentIndex: Int, totalTracks: Int) {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Disable previous button if at first track
        commandCenter.previousTrackCommand.isEnabled = (currentIndex > 0)

        // Disable next button if at last track
        commandCenter.nextTrackCommand.isEnabled = (currentIndex < totalTracks - 1)

        os_log(.info, log: logger, "🎛️ Playlist position: %d/%d - Previous: %{public}s, Next: %{public}s",
               currentIndex + 1, totalTracks,
               commandCenter.previousTrackCommand.isEnabled ? "enabled" : "disabled",
               commandCenter.nextTrackCommand.isEnabled ? "enabled" : "disabled")
    }

    // MARK: - Shuffle State Sync (for CarPlay shuffle button)

    /// Updates MPRemoteCommandCenter with current shuffle state from LMS
    /// Called after status queries to keep CarPlay shuffle button in sync
    func updateShuffleState(shuffleMode: Int) {
        // Map LMS shuffle mode to MPShuffleType
        // LMS: 0 = off, 1 = shuffle songs, 2 = shuffle albums
        let shuffleType: MPShuffleType
        switch shuffleMode {
        case 1:
            shuffleType = .items  // Shuffle songs
        case 2:
            shuffleType = .collections  // Shuffle albums
        default:
            shuffleType = .off
        }

        DispatchQueue.main.async {
            // Update CarPlay button visual state via MPRemoteCommandCenter
            MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = shuffleType

            os_log(.info, log: self.logger, "🔀 Shuffle state synced: LMS mode %d → CarPlay button %{public}s",
                   shuffleMode, shuffleType == .off ? "off" : (shuffleType == .items ? "songs" : "albums"))
        }
    }

    
    // MARK: - Track End Detection
    // REMOVED: Server-time based track end detection (was causing duplicate STMd signals)
    // Now using BASS_SYNC_END exclusively for reliable track end detection
    
    // MARK: - Debug Information
    func getTimeSourceInfo() -> String {
        let (currentTime, isPlaying, source) = getCurrentPlaybackInfo()
        let serverStatus = "SimpleTimeTracker (SlimProto)"
        
        // Simplified debug info - only show key information
        return """
        Time: \(String(format: "%.1f", currentTime))s (\(source.description))
        Playing: \(isPlaying ? "Yes" : "No")
        Server: \(serverStatus)
        """
    }
    
    // MARK: - Cleanup
    deinit {
        stopUpdateTimer()
        clearNowPlayingInfo()
        enableRemoteCommands(false)
        #if os(tvOS)
        NotificationCenter.default.removeObserver(self)
        #endif
        os_log(.info, log: logger, "Enhanced NowPlayingManager deinitialized")
    }

    #if os(tvOS)
    // MARK: - tvOS Idle Timer
    //
    // tvOS doesn't include PlaybackSessionController (iOS-only — CarPlay,
    // MPRemoteCommandCenter, AVAudioSession interruption handling all live
    // there). The Apple TV is a plugged-in living-room display where the
    // 2-minute system screensaver is too aggressive for a music app, so we
    // hook the idle timer here — at the single chokepoint that every play /
    // pause transition routes through (`updateNowPlayingInfo`).

    private func registerIdleTimerObservers() {
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(handleAppDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleAppWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification,
                           object: nil)
    }

    /// Called from `updateNowPlayingInfo` whenever the reported playback
    /// state changes, and from the tvOS Settings toggle's `onChange`.
    /// Mirrors the iOS gate (`keepScreenAwake && isPlaying`).
    func applyIdleTimerSetting() {
        let shouldDisable = SettingsManager.shared.keepScreenAwake && lastReportedIsPlaying
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = shouldDisable
            os_log(.debug, log: self.logger, "💡 Idle timer disabled: %{public}s", shouldDisable ? "YES" : "NO")
        }
    }

    @objc private func handleAppDidEnterBackground() {
        // Always release the timer on background — Top Shelf / Home button
        // shouldn't keep the screen awake even if playback is technically still
        // running on the server side.
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    @objc private func handleAppWillEnterForeground() {
        applyIdleTimerSetting()
    }

    fileprivate func reportPlaybackStateForIdleTimer(_ isPlaying: Bool) {
        guard isPlaying != lastReportedIsPlaying else { return }
        lastReportedIsPlaying = isPlaying
        applyIdleTimerSetting()
    }
    #endif
}

