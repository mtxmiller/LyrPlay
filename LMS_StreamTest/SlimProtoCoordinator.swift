// File: SlimProtoCoordinator.swift
// Enhanced with SimpleTimeTracker for accurate lock screen timing
import Foundation
import Combine
import UIKit
import os.log
#if os(iOS)
import WebKit
import MediaPlayer
import AVFoundation
#endif

extension Notification.Name {
    static let slimProtoDidConnect = Notification.Name("SlimProtoDidConnect")
}

// MARK: - Recovery Trigger Types
/// Defines what triggered a reconnection, determining recovery behavior
enum RecoveryTrigger {
    case none               // Normal connect (e.g., initial app launch)
    case appOpen            // App opened after background - muted + paused
    case lockScreen         // Lock screen play button - not muted + playing
    case networkRestored    // Network came back - resume previous state
}

class SlimProtoCoordinator: ObservableObject {
    
    // MARK: - Components
    private let client: SlimProtoClient
    private let commandHandler: SlimProtoCommandHandler
    private let connectionManager: SlimProtoConnectionManager
    private let audioManager: AudioManager
    private let simpleTimeTracker: SimpleTimeTracker // NEW: Material-style time tracking
    #if os(iOS)
    private weak var webView: WKWebView? // NEW: WebView for Material UI refresh
    #endif
    
    // MARK: - Dependencies
    private let settings = SettingsManager.shared
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoCoordinator")
    
    
    // MARK: - Settings Tracking (ADD THESE LINES)
    private(set) var lastKnownHost: String = ""
    private(set) var lastKnownPort: UInt16 = 3483
    private var playbackHeartbeatTimer: Timer?

    // 15s polling timer for radio (duration=0) streams. Necessary because LMS
    // typically transcodes radio source streams (Shoutcast/AAC with ICY) into
    // FLAC for mobile clients, which strips ICY metadata before BASS sees it.
    // BASS_SYNC_META therefore never fires for transcoded radio, leaving lock
    // screen / Now Playing artwork stale on track changes. The timer polls
    // fetchCurrentTrackMetadata() so LMS-side metadata (which Material WebView
    // already sees via cometd) reaches NowPlayingManager. Self-disables when
    // the stream turns out to have a known duration (file/podcast).
    private var metadataRefreshTimer: Timer?

    // MARK: - Metadata Last-Write-Wins Guard
    //
    // fetchCurrentTrackMetadata() fires from ~6 sites (initial stream, track
    // start, resume, radio-refresh tick, boundary-drift, ICY change). Around a
    // sync-group track boundary several overlap, so their HTTP responses can land
    // out of order. Without a guard, a stale response repaints the PREVIOUS
    // track's title/artist/album/position/bitrate — the intermittent staleness
    // bug. Each fetch stamps a monotonic seq; parse applies only if the response
    // is newer than the last one we APPLIED (not the last we fetched). Comparing
    // against last-applied — not last-fetched — means a good earlier response
    // still lands if the newest fetch errors out, instead of leaving the track
    // stale until the next boundary. Both are read/written on the main thread
    // only (all fetch sites dispatch to main), so no atomics needed. The accept
    // decision lives in MonotonicGate so it is unit-testable in isolation —
    // applyParsedMetadata depends on AudioManager and isn't unit-testable.
    private var metadataFetchSeq: Int = 0
    private var metadataGate = MonotonicGate()

    // MARK: - Background State Tracking
    private var isAppInBackground: Bool = false
    private var backgroundedWhilePlaying: Bool = false
    private var wasDisconnectedWhileInBackground: Bool = false
    private var backgroundedTime: Date?  // Track when app backgrounded for duration-based recovery

    // MARK: - Unified Recovery System (LMS_StreamTest-6lb)
    /// What triggered the current/pending reconnection - determines recovery behavior
    var pendingRecoveryTrigger: RecoveryTrigger = .none
    /// Was audio playing when connection was lost? (for networkRestored recovery)
    private var wasPlayingBeforeDisconnect: Bool = false
    /// Was audio paused when connection was lost? (for networkRestored recovery)
    private var wasPausedBeforeDisconnect: Bool = false

    // MARK: - Player Synchronization (Multi-room Audio)
    private var jiffiesEpoch: TimeInterval = 0  // Offset between server time and local jiffies
    private var jiffiesOffsetList: [TimeInterval] = []  // Track drift for corrections (max 8 entries)
    private var syncGroupID: Data?  // 10-byte sync group ID from serv packet (PHASE 5)
    private let syncController: SyncController  // BASS_ATTRIB_FREQ rate matching for sub-100ms drift

    // MARK: - ICY Metadata Tracking
    private var lastSentICYMetadata: (title: String?, artist: String?) = (nil, nil)

    // MARK: - Gapless Playback Tracking
    private var expectingGaplessTransition: Bool = false  // Set to true after sending STMd, false when STRM received

    /// Set in `didStartDirectStream` when the server's `strm 's'` arrives with
    /// `autostart='0'` (waitForSync). STMs send is deferred to `didResumeStream`
    /// (when the server's 'u' unpause lands). Sending STMs at strm-receipt time
    /// in this case prematurely jumps the server's controller state machine to
    /// PLAYING, which then drops the subsequent STMl and never issues 'u'.
    private var pendingUnpauseSTMs: Bool = false

    // MARK: - Legacy Timer (for compatibility)
    private var serverTimeTimer: Timer?
    private var lastServerTimeFetchLog: Date?


    // MARK: - Initialization
    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        self.client = SlimProtoClient()
        self.commandHandler = SlimProtoCommandHandler()
        self.connectionManager = SlimProtoConnectionManager()
        self.simpleTimeTracker = SimpleTimeTracker() // NEW: Initialize Material-style tracker
        self.syncController = SyncController(audioManager: audioManager)

        setupDelegation()
        setupAudioCallbacks()
        setupAudioPlayerIntegration()
        setupSyncController()
        #if os(iOS)
        setupBackgroundObservers()
        #endif

        #if DEBUG
        os_log(.info, log: logger, "SlimProtoCoordinator initialized with Material-style time tracking")
        #endif
    }
    
    // MARK: - Setup
    private func setupDelegation() {
        // Connect client to coordinator
        client.delegate = self
        
        // Connect command handler to client and coordinator
        commandHandler.slimProtoClient = client
        commandHandler.delegate = self
        
        
        client.commandHandler = commandHandler
        
        // Connect connection manager to coordinator
        connectionManager.delegate = self
    }
    
    private func setupAudioCallbacks() {
        // Set up track ended callback (already invoked on main — the BASS
        // end-sync in AudioPlayer.setupCallbacks marshals before delegating)
        audioManager.onTrackEnded = { [weak self] in
            self?.commandHandler.notifyTrackEnded()
        }
        
        // Connect audio manager back to coordinator for lock screen support
        audioManager.slimClient = self
    }
    
    func setupAudioManagerIntegration() {
        audioManager.setCommandHandler(commandHandler)
    }
    
    
    // MARK: - Audio Manager Integration Enhancement
    func setupNowPlayingManagerIntegration() {
        // Simple integration - just set the coordinator reference
        audioManager.getNowPlayingManager().setSlimClient(self)

        os_log(.info, log: logger, "✅ Simplified time tracking connected via AudioManager")
    }

    #if os(iOS)
    private func setupBackgroundObservers() {
        // Track app backgrounding for duration-based recovery
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        #if DEBUG
        os_log(.info, log: logger, "✅ Background observers configured for duration-based recovery")
        #endif
    }

    @objc private func handleAppDidEnterBackground() {
        backgroundedTime = Date()
        // Persist so recovery still fires after iOS kills the process during a long background
        UserDefaults.standard.set(backgroundedTime, forKey: "lyrplay_backgrounded_at")
        os_log(.info, log: logger, "📱 Coordinator: App backgrounded at %{public}s", backgroundedTime!.description)
    }
    #endif

    // MARK: - Public Interface
    func connect() {
        os_log(.info, log: logger, "Starting connection to %{public}s server...", settings.currentActiveServer.displayName)
        
        lastKnownHost = settings.activeServerHost
        lastKnownPort = UInt16(settings.activeServerSlimProtoPort)
        
        connectionManager.willConnect()
        client.updateServerSettings(host: settings.activeServerHost, port: UInt16(settings.activeServerSlimProtoPort))
        client.connect()
    }
    
    func disconnect() {
        os_log(.info, log: logger, "🔌 Disconnecting from server with position save")
        connectionManager.userInitiatedDisconnection()
        // DON'T stop server time sync immediately - preserve last known good time for lock screen
        // stopServerTimeSync()
        client.disconnectWithPositionSave()
    }
    
    func restartConnection() async {
        os_log(.info, log: logger, "🔄 Restarting connection to apply new capabilities...")
        
        // Quick disconnect without position saving (just a reconnect)
        client.disconnect()
        
        // Wait briefly for clean disconnect
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        
        // Reconnect with new capabilities
        await MainActor.run {
            connect()
        }
        
        os_log(.info, log: logger, "✅ Connection restart completed")
    }
    
    func updateServerSettings(host: String, port: UInt16) {
        // Store current settings for change detection
        lastKnownHost = host
        lastKnownPort = port

        // Update the client
        client.updateServerSettings(host: host, port: port)

        os_log(.info, log: logger, "Server settings updated and tracked - Host: %{public}s, Port: %d", host, port)
    }

    func resetConnectionManager() {
        // Reset ALL reconnection tracking to prevent failover interference when user manually changes servers
        connectionManager.resetAllReconnectionTracking()
        os_log(.info, log: logger, "✅ Connection manager reset - all reconnection tracking cleared")
    }

    func getBackgroundDuration() -> TimeInterval? {
        if let bgTime = backgroundedTime {
            return Date().timeIntervalSince(bgTime)
        }
        // In-memory value is lost when iOS terminates the process during long backgrounds.
        // Fall back to the persisted timestamp so app-open and lock-screen-play recovery
        // still fire on the relaunched process.
        if let persistedBgTime = UserDefaults.standard.object(forKey: "lyrplay_backgrounded_at") as? Date {
            return Date().timeIntervalSince(persistedBgTime)
        }
        return nil
    }

    /// Request server-side seek for transcoding pipeline fixes
    // MARK: - Server Time Sync Management (Using SimpleTimeTracker)
    private func startServerTimeSync() {
        os_log(.debug, log: logger, "🔄 Using simplified SlimProto time tracking")
    }
    
    private func stopServerTimeSync() {
        os_log(.debug, log: logger, "⏹️ Simplified time tracking stopped")
    }
    
    func requestFreshMetadata() {
        os_log(.info, log: logger, "🔄 Requesting fresh metadata due to stream change")
        fetchCurrentTrackMetadata()
    }

    /// Whether ICY metadata should be pushed back to LMS via the squeezelite META command.
    /// Rule #11: ICY metadata for duration=0 (infinite radio) streams crashes LMS
    /// XMLBrowser.pm line 1975 ("Can't call method 'duration' on an undefined value").
    /// Only file/streamable content with a known duration can safely receive META.
    /// Extracted as a pure predicate so the rule-#11 invariant is unit-testable
    /// without constructing a full SlimProtoCoordinator.
    internal static func shouldSendICYToLMS(streamDuration: TimeInterval) -> Bool {
        return streamDuration > 0
    }

    func handleICYMetadata(_ metadata: (title: String?, artist: String?)) {
        // Filter duplicate metadata to prevent spam
        let isDuplicate = (metadata.title == lastSentICYMetadata.title &&
                          metadata.artist == lastSentICYMetadata.artist)

        if isDuplicate {
            // Skip duplicate without logging (happens constantly)
            return
        }

        os_log(.info, log: logger, "🎵 New ICY metadata: title=%{public}s, artist=%{public}s",
               metadata.title ?? "nil", metadata.artist ?? "nil")

        // Store metadata to prevent future duplicates
        lastSentICYMetadata = metadata

        // Conditionally push ICY back to LMS for file streams (squeezelite META).
        // Skip for duration=0 (radio) per rule #11 — would crash LMS XMLBrowser.pm.
        let duration = audioManager.getDuration()
        if Self.shouldSendICYToLMS(streamDuration: duration) {
            os_log(.info, log: logger, "🎵 Stream has duration (%.2fs) - sending ICY metadata to LMS", duration)
            sendICYMetadataToLMS(title: metadata.title, artist: metadata.artist)
        } else {
            os_log(.info, log: logger, "🎵 Stream has no duration (infinite stream) - skipping ICY metadata send (prevents server crash)")
        }

        // Always refresh OUR view of metadata regardless of duration. ICY arrival
        // signals a track change; LMS-side metadata (artwork URL, album, etc.) is
        // updated by the source plugin (Radio Paradise, etc.) on its own schedule.
        // Hybrid timing: 0.5s catches plugins that update metadata before our BASS
        // callback fires; 2.5s safety net catches plugins that poll their source
        // slightly after us. Two cheap JSON-RPC calls per ~3-5 minute radio track.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestFreshMetadata()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.requestFreshMetadata()
        }
    }

    private func sendICYMetadataToLMS(title: String?, artist: String?) {
        let playerID = settings.playerMACAddress

        // Create metadata string in the format LMS expects
        var metadataArray: [String] = []

        if let title = title {
            metadataArray.append("title")
            metadataArray.append(title)
        }

        if let artist = artist {
            metadataArray.append("artist")
            metadataArray.append(artist)
        }

        guard !metadataArray.isEmpty else {
            os_log(.debug, log: logger, "🎵 No metadata to send to LMS")
            return
        }

        // Send ICY metadata update to LMS (similar to squeezelite META command)
        let metadataCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["icy"] + metadataArray]
        ]

        sendJSONRPCCommandDirect(metadataCommand) { [weak self] response in
            os_log(.info, log: self?.logger ?? OSLog.default, "🎵 ICY metadata sent to LMS server")
        }
    }
    
    private func startPlaybackHeartbeat() {
        stopPlaybackHeartbeat()

        // Only during active playback, send STMt every second like squeezelite
        // NOTE: Position saving moved to NowPlayingManager.updateNowPlayingTime() (LMS_StreamTest-6lb)
        // NowPlayingManager's timer never stops, so position is saved even when disconnected
        //
        // Scheduled on RunLoop.main in .common mode (NOT Timer.scheduledTimer which uses
        // .default) so it fires reliably during WebView scroll/animation, lock-screen
        // transitions, and background-audio mode. With .default, multi-room sync would
        // see 3-5s STMt gaps whenever the main thread entered tracking mode, causing
        // the LMS server to bail on the sync group ("playPoint too old"). Same fix as
        // the radio metadata refresh timer (commit 397beac).
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Only process if actively playing (not paused/stopped)
            let playerState = self.audioManager.getPlayerState()
            if playerState == "Playing" && !self.commandHandler.isPausedByLockScreen {
                // Send STMt to server (will fail silently if disconnected)
                self.client.sendStatus("STMt")
                // Drive SyncController on the same cadence as STMt — server measures
                // drift from STMt timestamps, so our rate corrections decide right when
                // the server sees fresh data.
                self.tickSyncController()
                // Sample wire bitrate from BASS_FILEPOS_DOWNLOAD and apply to
                // AudioPlayer.StreamInfo. Replaces LMS's source-file bitrate
                // with the *actual* stream bitrate — correct for transcoded
                // streams. nil during the initial ~3s prefetch burst, then
                // stabilizes over the measurement window.
                self.audioManager.sampleAndApplyMeasuredBitrate()
            }
        }
        playbackHeartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackHeartbeat() {
        playbackHeartbeatTimer?.invalidate()
        playbackHeartbeatTimer = nil
    }

    /// Polls fresh metadata every 15s for radio streams (duration=0). Mirrors
    /// the lifecycle of startPlaybackHeartbeat — tied to active playback only.
    /// First tick checks duration; if > 0 (track-based content) the timer
    /// stops itself, so this is safe to call unconditionally on stream start.
    /// Scheduled on RunLoop.main in .common mode so it fires reliably while
    /// the app is backgrounded under UIBackgroundModes=audio (the default
    /// .default mode can be paused for non-audio threads in background).
    private func startRadioMetadataRefreshTimer() {
        stopRadioMetadataRefreshTimer()
        os_log(.info, log: logger, "🔄 Starting radio metadata refresh timer (15s interval)")

        let timer = Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Self-disable for track-based content; sendTrackStarted handles those refreshes.
            let duration = self.audioManager.getDuration()
            if duration > 0 {
                os_log(.info, log: self.logger, "🔄 Stream has duration %.2fs - stopping radio metadata refresh timer", duration)
                self.stopRadioMetadataRefreshTimer()
                return
            }

            // Skip while paused or lock-screen-paused; resume() restarts the timer.
            let playerState = self.audioManager.getPlayerState()
            guard playerState == "Playing", !self.commandHandler.isPausedByLockScreen else { return }

            os_log(.debug, log: self.logger, "🔄 Radio metadata refresh tick")
            self.fetchCurrentTrackMetadata()
        }
        metadataRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRadioMetadataRefreshTimer() {
        metadataRefreshTimer?.invalidate()
        metadataRefreshTimer = nil
    }

    // MARK: - Connection State (Enhanced)
    var connectionState: String {
        return connectionManager.connectionState.displayName
    }
    
    var isConnected: Bool {
        return connectionManager.connectionState.isConnected
    }
    
    var streamState: String {
        return commandHandler.streamState
    }
    
    var networkStatus: String {
        return connectionManager.networkStatus.displayName
    }
    
    var connectionSummary: String {
        return connectionManager.connectionSummary
    }
    
    var isInBackground: Bool {
        return connectionManager.isInBackground
    }
    
    var backgroundTimeRemaining: TimeInterval {
        return connectionManager.backgroundTimeRemaining
    }
    
    // MARK: - Server Time Debug Info
    var serverTimeStatus: String {
        return "Simplified SlimProto Time Tracking"
    }
    
    var timeSourceInfo: String {
        return audioManager.getTimeSourceInfo()
    }
    
    // REMOVED: Timer-based metadata refresh - replaced with BASS ICY metadata callbacks
    
    // REMOVED: ensureRadioMetadataRefreshIsRunning - redundant with fetchCurrentTrackMetadata
    
    private func setupAudioPlayerIntegration() {
        audioManager.setCommandHandler(commandHandler)
    }
    
    // MARK: - Audio Player Event Handlers
    func handleAudioPlayerDidStartPlaying() {
        os_log(.info, log: logger, "🎵 Audio playback actually started - sending STMs")
        
        // This is when we should send STMs (track started playing)
        // Only after RESP and STMc have been sent
        client.sendStatus("STMs")
    }
    
    deinit {
        stopServerTimeSync()
        stopServerTimeFetching()  // Stop our simplified server time fetching
        // Use position-saving disconnect when app is being deallocated
        client.disconnectWithPositionSave()
    }
    
    // MARK: - Recovery State Management
    private var isRecoveryInProgress = false
    // Armed during silent (app-open) recovery once the pause command is sent. The unmute
    // is gated on the real STMp pause confirmation in didPauseStream() rather than a fixed
    // timer, so DSP gain is only restored after audio has actually stopped flowing.
    private var awaitingSilentRecoveryUnmute = false
    private let recoveryQueue = DispatchQueue(label: "recovery.queue", qos: .userInitiated)
    
    // MARK: - Playlist-Based Position Recovery (Home Assistant Approach)
    
    /// Save current playback position and playlist state for recovery
    func saveCurrentPositionForRecovery() {
        // Get current position from SimpleTimeTracker (most accurate, live position)
        let currentPosition = getCurrentTimeForSaving()
        guard currentPosition > 0 else {
            os_log(.info, log: logger, "💾 No current position to save for recovery")
            return
        }
        
        // Query server for current playlist state (but use local time for position)
        let statusCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["status", "-", 1, "tags:u,K,c"]]
        ]
        
        sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
            guard let self = self,
                  let result = response["result"] as? [String: Any] else {
                os_log(.info, log: self?.logger ?? OSLog.default, "💾 Could not get server status for recovery")
                return
            }
            
            // Parse playlist_cur_index - could be Int or String
            let playlistCurIndex: Int
            if let indexAsInt = result["playlist_cur_index"] as? Int {
                playlistCurIndex = indexAsInt
            } else if let indexAsString = result["playlist_cur_index"] as? String, 
                      let indexParsed = Int(indexAsString) {
                playlistCurIndex = indexParsed
            } else {
                os_log(.info, log: self.logger, "💾 Could not parse playlist index for recovery: %{public}@", 
                       String(describing: result["playlist_cur_index"]))
                return
            }
            
            // Save to user preferences for recovery (using live position, not server time)
            UserDefaults.standard.set(playlistCurIndex, forKey: "lyrplay_recovery_index")
            UserDefaults.standard.set(currentPosition, forKey: "lyrplay_recovery_position") 
            UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
            
            os_log(.info, log: self.logger, "💾 Saved recovery state: track %d at %.2f seconds (live position)", playlistCurIndex, currentPosition)
        }
    }
    
    /// Perform playlist jump recovery with context-aware play/pause behavior
    /// - Parameter shouldPlay: If true, starts playing after jump (noplay=0). If false, stays paused (noplay=1)
    /// Clear the silent-recovery unmute latch and restore DSP gain, always on the main
    /// queue so the flag access is serialized with the arming and fallback timers (also on
    /// main). Safe no-op if the latch isn't armed. Call sites (didPauseStream/didStopStream)
    /// run on the socket queue, so this hop also keeps the BASS gain restore off that thread.
    private func finishSilentRecoveryIfArmed(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.awaitingSilentRecoveryUnmute else { return }
            self.awaitingSilentRecoveryUnmute = false
            self.audioManager.disableSilentRecoveryMode()
            os_log(.info, log: self.logger, "🔊 Silent recovery complete - volume restored (%{public}s)", reason)
        }
    }

    func performPlaylistRecovery(shouldPlay: Bool = true) {
        recoveryQueue.async { [weak self] in
            guard let self = self else { return }

            // Check if recovery is already in progress
            guard !self.isRecoveryInProgress else {
                os_log(.info, log: self.logger, "🔒 Playlist Recovery: Skipping - recovery already in progress")
                return
            }

            // Set recovery in progress
            self.isRecoveryInProgress = true
            os_log(.error, log: self.logger, "[APP-RECOVERY] 🔒 PLAYLIST RECOVERY STARTED (shouldPlay: %{public}s)", shouldPlay ? "YES" : "NO")

            DispatchQueue.main.async { [weak self] in
                self?.executePlaylistRecovery(shouldPlay: shouldPlay)
            }
        }
    }

    private func executePlaylistRecovery(shouldPlay: Bool) {
        os_log(.error, log: logger, "[APP-RECOVERY] 🎯 EXECUTING PLAYLIST RECOVERY (shouldPlay: %{public}s)", shouldPlay ? "YES" : "NO")

        // CRITICAL FIX: Add timeout to prevent permanent recovery lock if JSONRPC callback fails
        // This prevents CarPlay "Resume Playback" from hanging on subsequent attempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self else { return }
            if self.isRecoveryInProgress {
                os_log(.error, log: self.logger, "⚠️ RECOVERY TIMEOUT - Clearing lock after 10s (callback likely failed)")
                self.isRecoveryInProgress = false
                // Don't leave audio muted if the jump callback never fires — handlePendingRecovery(.appOpen)
                // sets the mute flags before this function runs, and only the success callback unmutes.
                self.awaitingSilentRecoveryUnmute = false
                self.audioManager.disableSilentRecoveryMode()
            }
        }

        // NOTE: FLAC restriction removed - FLAC now uses legacy URL streaming (not push streams)
        // which supports seeking via server-side transcoding. Playlist jump recovery works for all formats.

        // Check if we have recovery data (no time limit - like other music players)
        guard UserDefaults.standard.object(forKey: "lyrplay_recovery_timestamp") != nil else {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔄 No recovery data - using simple %{public}s command", shouldPlay ? "play" : "pause")
            // handlePendingRecovery(.appOpen) mutes the audio engine before this function runs.
            // Undo it here so a missing-data early-return doesn't leave the next stream silent.
            audioManager.disableSilentRecoveryMode()
            sendJSONRPCCommand(shouldPlay ? "play" : "pause")
            isRecoveryInProgress = false // Clear recovery flag
            return
        }

        let savedIndex = UserDefaults.standard.integer(forKey: "lyrplay_recovery_index")
        let savedPosition = UserDefaults.standard.double(forKey: "lyrplay_recovery_position")

        guard savedPosition > 0 else {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔄 No saved position - using simple %{public}s command", shouldPlay ? "play" : "pause")
            // Same mute-leak guard as the recovery_timestamp early-return above.
            audioManager.disableSilentRecoveryMode()
            sendJSONRPCCommand(shouldPlay ? "play" : "pause")
            isRecoveryInProgress = false // Clear recovery flag
            return
        }

        os_log(.error, log: logger, "[APP-RECOVERY] 🎯 Performing playlist recovery: jump to track %d at %.2f seconds (shouldPlay: %{public}s)",
               savedIndex, savedPosition, shouldPlay ? "YES" : "NO")

        // SILENT RECOVERY: Set mute flag BEFORE playlist jump for app foreground recovery
        if !shouldPlay {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔇 ENABLING SILENT RECOVERY MODE BEFORE PLAYLIST JUMP")
            audioManager.enableSilentRecoveryMode()
            os_log(.error, log: logger, "[APP-RECOVERY] ✅ Silent recovery mode enabled - next stream will be muted")
        } else {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔊 Normal recovery mode - no muting needed")
        }

        // CRITICAL: Always use noplay=0 (play) because noplay=1 doesn't work on STOPPED clients
        // After 300s server forget, new client is STOPPED, and noplay=1 only calls resetSongqueue()
        // which doesn't actually seek to the position. So we always play, then pause if needed.
        let noplayFlag = 0  // Always start playing

        let playlistJumpCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, [
                "playlist", "jump", savedIndex, 1, noplayFlag, [
                    "timeOffset": savedPosition
                ]
            ]]
        ]
        
        sendJSONRPCCommandDirect(playlistJumpCommand) { [weak self] response in
            guard let self = self else { return }
            os_log(.info, log: self.logger, "🎯 Playlist jump recovery completed")

            // If we jumped with shouldPlay=false, pause after stream establishes (silently muted)
            // Longer delay (1.5s) ensures stream is fully established before pause
            if !shouldPlay {
                os_log(.info, log: self.logger, "⏸️ App foreground recovery: waiting for silent stream to establish, then pausing")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    // Arm the event-gated unmute BEFORE sending pause. didPauseStream() will
                    // restore volume the moment the STMp pause confirmation lands — i.e. once
                    // BASS is actually paused. The old fixed +2s timer could fire while the
                    // stream was still playing (or before the async STRM start landed), which
                    // is what leaked the intermittent (~10%) blip.
                    self.awaitingSilentRecoveryUnmute = true

                    // Send pause command (channel still muted)
                    self.sendJSONRPCCommand("pause")

                    // Fallback ceiling: if the pause confirmation never arrives, unmute anyway
                    // so the engine is never left muted. No-op if didPauseStream already did it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                        guard self.awaitingSilentRecoveryUnmute else { return }
                        self.awaitingSilentRecoveryUnmute = false
                        self.audioManager.disableSilentRecoveryMode()
                        os_log(.info, log: self.logger, "🔊 Silent recovery complete - volume restored (fallback timer)")
                    }
                }
            }

            // Clear recovery flag after completion
            self.isRecoveryInProgress = false
            os_log(.info, log: self.logger, "🔒 Recovery state cleared - other recovery methods can now proceed")

            // Clear recovery data after successful use
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_index")
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_position")
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_timestamp")
        }
    }

    // MARK: - Unified Recovery Handler (LMS_StreamTest-6lb)

    /// Handle pending recovery based on trigger type - called from slimProtoDidConnect()
    /// This is the SINGLE entry point for all recovery scenarios, preventing conflicts
    func handlePendingRecovery() {
        let trigger = pendingRecoveryTrigger
        pendingRecoveryTrigger = .none  // Reset immediately to prevent double-execution

        switch trigger {
        case .appOpen:
            // App open recovery: muted + paused (unique silent recovery feature)
            guard settings.enableAppOpenRecovery else {
                os_log(.info, log: logger, "🔇 App open recovery: disabled in settings - skipping")
                return
            }
            // Consume the persisted background timestamp so a stale value can't keep
            // re-triggering app-open recovery on every future cold launch.
            // Scoped to .appOpen only — .lockScreen and .networkRestored leave it alone
            // so a subsequent cold launch can still gate on it.
            UserDefaults.standard.removeObject(forKey: "lyrplay_backgrounded_at")
            backgroundedTime = nil

            #if os(iOS)
            // CarPlay returns to the car expecting playback to RESUME, not land paused.
            // The muted "jump → pause" dance fights CarPlay's own autoplay and (when its
            // fixed-timer mute races the async stream) leaks an audible blip. When CarPlay
            // is the active output we still need the playlist jump — the server has forgotten
            // our position after the 300s forget window, so a bare play won't resume — but
            // with shouldPlay=true: jump and play at the saved position, no mute, no pause.
            let carPlayConnected = AVAudioSession.sharedInstance().currentOutputs.contains(.carAudio)
            if carPlayConnected {
                os_log(.info, log: logger, "🚗 App open recovery: CarPlay connected - resuming (jump + play, no mute/pause)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.performPlaylistRecovery(shouldPlay: true)
                }
                return
            }
            #endif

            os_log(.info, log: logger, "🔇 App open recovery: muted + paused")
            audioManager.enableSilentRecoveryMode()  // Mute before server sends audio

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.performPlaylistRecovery(shouldPlay: false)
            }

        case .lockScreen:
            // Lock screen recovery: not muted + playing
            os_log(.info, log: logger, "🔊 Lock screen recovery: playing")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.performPlaylistRecovery(shouldPlay: true)
            }

        case .networkRestored:
            // Network restored: resume previous state
            os_log(.info, log: logger, "🔄 Network restored recovery: wasPlaying=%{public}s", wasPlayingBeforeDisconnect ? "YES" : "NO")

            // Only recover if we were playing or paused before disconnect.
            // Paused sessions additionally honor enableAppOpenRecovery: before
            // the Paused-state fix (433.1.4) a paused push stream misreported
            // "Stopped", so the paused arm here never fired — restoring a
            // paused session is app-open recovery in the user's mental model,
            // and must respect the toggle. Playing sessions always recover
            // (mid-playback continuity, not app-open recovery).
            guard wasPlayingBeforeDisconnect || (wasPausedBeforeDisconnect && settings.enableAppOpenRecovery) else {
                os_log(.info, log: logger, "🔄 Network restored: no recovery needed (playing=%{public}s, paused=%{public}s, appOpenRecovery=%{public}s)",
                       wasPlayingBeforeDisconnect ? "YES" : "NO",
                       wasPausedBeforeDisconnect ? "YES" : "NO",
                       settings.enableAppOpenRecovery ? "ON" : "OFF")
                return
            }

            let shouldPlay = wasPlayingBeforeDisconnect

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.performPlaylistRecovery(shouldPlay: shouldPlay)
            }

        case .none:
            // No recovery needed - normal connect (e.g., initial app launch)
            os_log(.info, log: logger, "📡 Normal connect - no recovery needed")
        }
    }
}

// MARK: - SlimProtoClientDelegate
extension SlimProtoCoordinator: SlimProtoClientDelegate {
    
    func slimProtoDidConnect() {
        os_log(.info, log: logger, "✅ Connection established")
        connectionManager.didConnect()
        syncControllerReset(reason: "slimProtoDidConnect")

        // Don't start any status timers here
        // Heartbeat only starts during playback

        startServerTimeSync()
        setupNowPlayingManagerIntegration()

        // Apply tvOS volume policy if user opted in (fixOutputAt100Percent).
        // Disables LMS software volume attenuation and forces volume to 100%.
        applyFixedOutputPolicyIfNeeded()

        // UNIFIED RECOVERY: Handle based on trigger type (LMS_StreamTest-6lb)
        // This replaces separate recovery calls in ContentView and sendLockScreenCommand
        handlePendingRecovery()

        // Notify observers (CarPlay uses this for event-driven data loading)
        NotificationCenter.default.post(name: .slimProtoDidConnect, object: nil)
    }

    func slimProtoDidDisconnect(error: Error?) {
        os_log(.info, log: logger, "🔌 Connection lost")

        // UNIFIED RECOVERY: Capture playback state for networkRestored recovery (LMS_StreamTest-6lb)
        let playerState = audioManager.getPlayerState()
        wasPlayingBeforeDisconnect = (playerState == "Playing")
        wasPausedBeforeDisconnect = (playerState == "Paused")
        os_log(.info, log: logger, "📊 Disconnect state: wasPlaying=%{public}s, wasPaused=%{public}s",
               wasPlayingBeforeDisconnect ? "YES" : "NO", wasPausedBeforeDisconnect ? "YES" : "NO")

        // UNIFIED RECOVERY: Save position immediately (don't wait for timer)
        // Use interpolated server time (not decoder position) for accurate recovery
        let position = getCurrentTimeForSaving()
        if position > 0 {
            UserDefaults.standard.set(position, forKey: "lyrplay_recovery_position")
            UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "lyrplay_recovery_index"), forKey: "lyrplay_recovery_index")
            os_log(.info, log: logger, "💾 Saved recovery state on disconnect: %.2f seconds (interpolated)", position)
        }

        // Track if we were disconnected while in background (for app open recovery)
        if isAppInBackground {
            wasDisconnectedWhileInBackground = true
            os_log(.info, log: logger, "📱 Disconnected while in background - recovery will be needed")
        }

        // CRITICAL: Also save full recovery state (includes track index from server)
        saveCurrentPositionForRecovery()

        // Trust server-master architecture: Server controls playback via STRM commands
        // Don't send local stop commands - let server decide when to stop/start via STRM

        connectionManager.didDisconnect(error: error)

        stopPlaybackHeartbeat()
        stopServerTimeSync()
    }
    
    func slimProtoDidReceiveCommand(_ command: SlimProtoCommand) {
        // Record that we received a command (shows connection is alive)
        connectionManager.recordHeartbeatResponse()

        // Handle serv packet for sync group persistence
        if command.type == "serv" {
            handleServPacket(command.payload)
        }

        // Forward to command handler
        commandHandler.processCommand(command)
    }
}

// MARK: - Enhanced SlimProtoConnectionManagerDelegate
extension SlimProtoCoordinator: SlimProtoConnectionManagerDelegate {
    
    func connectionManagerShouldReconnect() {
        os_log(.info, log: logger, "🔄 Connection manager requesting reconnection")

        // UNIFIED RECOVERY: Set trigger if we were playing/paused before disconnect (LMS_StreamTest-6lb)
        if wasPlayingBeforeDisconnect || wasPausedBeforeDisconnect {
            pendingRecoveryTrigger = .networkRestored
            os_log(.info, log: logger, "🔄 Network restored trigger set (wasPlaying: %{public}s)",
                   wasPlayingBeforeDisconnect ? "YES" : "NO")
        }

        // IMPROVED FAILOVER: Switch servers if current server keeps failing
        let reconnectionAttempts = connectionManager.getReconnectionAttempts()

        // Try backup server if primary fails twice (fast failover, issue #76).
        // >= 2 (not >= 1) so a single transient blip on a normally-reachable
        // primary — dropped first SYN, momentary Wi-Fi stall, server mid-restart —
        // gets one free retry before we abandon it for backup.
        if settings.automaticFailoverEnabled &&
           settings.currentActiveServer == .primary &&
           reconnectionAttempts >= 2 &&
           settings.isBackupServerEnabled &&
           !settings.backupServerHost.isEmpty {

            os_log(.info, log: logger, "🔄 Primary server failed after %d attempts - switching to backup (session-only)", reconnectionAttempts)
            settings.failoverToBackupServer()

            // Update client with backup server settings
            client.updateServerSettings(
                host: settings.activeServerHost,
                port: UInt16(settings.activeServerSlimProtoPort)
            )

            // CRITICAL: Reset reconnection counter when switching servers
            connectionManager.resetReconnectionAttempts()
        }
        // Try primary server if backup fails twice (fast failover).
        // Symmetric with the forward branch: >= 2 absorbs one transient backup
        // blip, and the non-empty primary-host guard prevents snapping to an
        // empty/unreachable primary and reconnect-looping.
        else if settings.automaticFailoverEnabled &&
                settings.currentActiveServer == .backup &&
                reconnectionAttempts >= 2 &&
                !settings.serverHost.isEmpty {

            os_log(.info, log: logger, "🔄 Backup server failed after %d attempts - falling back to primary (session-only)", reconnectionAttempts)
            settings.failoverToPrimaryServer()

            // Update client with primary server settings
            client.updateServerSettings(
                host: settings.activeServerHost,
                port: UInt16(settings.activeServerSlimProtoPort)
            )

            // CRITICAL: Reset reconnection counter when switching servers
            connectionManager.resetReconnectionAttempts()
        }

        client.connect()
    }
    
    func connectionManagerDidEnterBackground() {
        isAppInBackground = true
        
        os_log(.info, log: logger, "📱 App backgrounded - saving position for potential recovery")
        
        // CRITICAL: Save current position for playlist recovery
        saveCurrentPositionForRecovery()
        
        let isLockScreenPaused = commandHandler.isPausedByLockScreen
        let playerState = audioManager.getPlayerState()
        
        
        // Position will be saved automatically by server's power management
        
        if playerState == "Paused" || playerState == "Stopped" {
            backgroundedWhilePlaying = false
            os_log(.info, log: logger, "⏸️ App backgrounded while paused - staying connected (will disconnect when iOS background time expires)")
            
            // DON'T disconnect immediately - let connection manager handle background time limits
            // This allows for quick resume if user returns to app soon
            
        } else {
            backgroundedWhilePlaying = true
            os_log(.info, log: logger, "▶️ App backgrounded while playing - maintaining connection for background audio")
            // Keep connection alive for active playback
        }
    }
    
    func connectionManagerDidEnterForeground() {
        isAppInBackground = false
        backgroundedWhilePlaying = false
        // Note: Don't clear wasDisconnectedWhileInBackground here - let recovery handle it
        
        os_log(.info, log: logger, "📱 App foregrounded")
        
        if connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "Already connected - server auto-resume will handle position recovery")
        } else {
            connect()
        }
    }
    
    
    
    // MARK: - Fixed Output Volume Policy (tvOS — see Elissen #10 design doc)

    /// Disables LMS software volume attenuation on the player and forces volume
    /// to 100%. Maps to the same setting Material exposes as Player Settings →
    /// Audio → "Output level is fixed at 100%". Used on tvOS so the TV / AVR /
    /// soundbar owns the volume axis — the LMS player stays out of the chain.
    ///
    /// Called from `slimProtoDidConnect` when `settings.fixOutputAt100Percent` is
    /// true, and from the tvOS Settings toggle handler when the user flips it ON.
    func applyFixedOutputPolicy() {
        let playerID = settings.playerMACAddress
        guard !playerID.isEmpty else {
            os_log(.info, log: logger, "🔇 Skipping fixed-output policy — no playerID yet")
            return
        }

        let prefCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playerpref", "digitalVolumeControl", 0]]
        ]
        let volumeCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["mixer", "volume", 100]]
        ]

        os_log(.info, log: logger, "🔊 Applying fixed-output policy (digitalVolumeControl=0, volume=100)")
        sendJSONRPCCommandDirect(prefCommand) { _ in }
        sendJSONRPCCommandDirect(volumeCommand) { _ in }
    }

    /// Restores LMS software volume control (`digitalVolumeControl=1`). Called
    /// from the tvOS Settings toggle handler when the user flips
    /// `fixOutputAt100Percent` OFF. Does NOT touch the current volume — leaves
    /// it at whatever LMS has.
    func restoreSoftwareVolumeControl() {
        let playerID = settings.playerMACAddress
        guard !playerID.isEmpty else { return }

        let prefCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playerpref", "digitalVolumeControl", 1]]
        ]

        os_log(.info, log: logger, "🔊 Restoring software volume control (digitalVolumeControl=1)")
        sendJSONRPCCommandDirect(prefCommand) { _ in }
    }

    /// On-connect hook. Re-applies the fixed-output policy if the user has it
    /// enabled. Behavior chosen for predictability: every successful tvOS
    /// connect re-asserts the policy. A user who wants software volume on the
    /// tvOS player toggles the Settings option OFF — that path doesn't call
    /// this method.
    private func applyFixedOutputPolicyIfNeeded() {
        guard settings.fixOutputAt100Percent else { return }
        applyFixedOutputPolicy()
    }

    // MARK: - Custom Position Banking (Server Preferences)

    private func savePositionToServerPreferences() {
        let (currentTime, _) = getCurrentInterpolatedTime()
        let playerState = audioManager.getPlayerState()
        
        guard currentTime > 0.1 else {
            os_log(.info, log: logger, "⚠️ No valid position to save to server preferences")
            return
        }
        
        os_log(.info, log: logger, "💾 Saving position to server preferences: %.2f seconds (state: %{public}s)", 
               currentTime, playerState)
        
        let playerID = settings.playerMACAddress
        
        // Save position
        let savePositionCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playerpref", "lyrPlayLastPosition", String(format: "%.2f", currentTime)]]
        ]
        
        // Save player state (paused/playing)
        let saveStateCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request", 
            "params": [playerID, ["playerpref", "lyrPlayLastState", playerState]]
        ]
        
        // Save timestamp for validation
        let saveTimestampCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playerpref", "lyrPlaySaveTime", String(Int(Date().timeIntervalSince1970))]]
        ]
        
        // Send all preference updates (fire and forget - no completion needed)
        sendJSONRPCCommandDirect(savePositionCommand) { _ in }
        sendJSONRPCCommandDirect(saveStateCommand) { _ in }
        sendJSONRPCCommandDirect(saveTimestampCommand) { _ in }
    }
    
    func connectionManagerNetworkDidChange(isAvailable: Bool, isExpensive: Bool) {
        os_log(.info, log: logger, "🌐 Network change - Available: %{public}s, Expensive: %{public}s",
               isAvailable ? "YES" : "NO", isExpensive ? "YES" : "NO")
        
        if isAvailable {
            // Network became available - adjust strategy if needed
            if connectionManager.connectionState.canAttemptConnection {
                os_log(.info, log: logger, "🌐 Network available - attempting connection")
                connect()
            } else if connectionManager.connectionState.isConnected {
                // Network restored - server time sync will continue
            }
        } else {
            // Network lost - server time sync will automatically handle this
            os_log(.debug, log: logger, "🌐 Network lost - server time sync will fall back to local time")
        }
        
    }
    
    func connectionManagerShouldCheckHealth() {
        // Server polls us with strm 't' commands
        // No need to send unsolicited status
    }
    
    
}

// MARK: - SlimProtoCommandHandlerDelegate
extension SlimProtoCoordinator: SlimProtoCommandHandlerDelegate {
    
    func didStartStream(url: String, format: String, startTime: Double, replayGain: Float) {
        os_log(.info, log: logger, "🎵 Starting stream: %{public}s from %.2f with replayGain %.4f", format, startTime, replayGain)

        // Stop any existing playback and timers first
        //audioManager.stop() - removed - testing faux gapless
        stopPlaybackHeartbeat()

        // Track end detection now handled exclusively by BASS_SYNC_END callback

        if startTime > 0 {
            audioManager.playStreamAtPositionWithFormat(urlString: url, startTime: startTime, format: format, replayGain: replayGain)
        } else {
            audioManager.playStreamWithFormat(urlString: url, format: format, replayGain: replayGain)
        }
        
        // Start periodic server time fetching for lock screen updates
        startServerTimeFetching()

        // Start the 1-second heartbeat timer (like squeezelite)
        startPlaybackHeartbeat()

        // Start radio metadata refresh poll (self-disables for non-radio streams).
        startRadioMetadataRefreshTimer()

        // Get initial metadata for new stream
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.fetchCurrentTrackMetadata()
        }

        // Fetch server time after connection stabilizes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.fetchServerTime()
        }
    }

    func didStartDirectStream(url: String, format: String, startTime: Double, replayGain: Float, autostart: UInt8) {
        // autostart byte from the SlimProto strm packet (per Squeezebox.pm:519):
        //   '0' (0x30) = WAIT for unpause ('u')                           — used for sync groups + fade-in transitions
        //   '1' (0x31) = autoplay immediately
        //   '2' (0x32) = direct streaming variant of '0' — also WAIT      — sent when LMS adds +2 for direct-streaming handlers
        //   '3' (0x33) = direct streaming variant of '1' — autoplay
        // For '0' or '2' we must defer BASS_ChannelPlay until 'u' arrives; otherwise
        // BASS gets ~300ms of head start over squeezelite peers in a sync group, OR
        // races with the server's fade-in volume ramp. Either is audible.
        let waitForUnpause = (autostart == UInt8(ascii: "0") || autostart == UInt8(ascii: "2"))
        // Reset the deferred-STMs flag at the start of every track. This guards
        // against the flag leaking if a sync-wait track is interrupted before its
        // 'u' arrives (e.g., user hits next, server sends strm 'q' then a new 's').
        pendingUnpauseSTMs = false
        os_log(.info, log: logger, "📊 Starting DIRECT stream (gapless mode): %{public}s from %.2f with replayGain %.4f (autostart='%c', waitForSync=%{public}s)",
               format, startTime, replayGain, Int32(autostart), waitForUnpause ? "YES" : "NO")
        os_log(.debug, log: logger, "📊 Stream URL: %{public}s", url)

        // Stop any existing playback and timers first
        stopPlaybackHeartbeat()

        // Check if this is a gapless transition (track decode completed naturally)
        let isGapless = expectingGaplessTransition
        if isGapless {
            os_log(.info, log: logger, "🎵 Gapless transition detected - queuing next track while old audio plays")
        }

        // Start push stream playback with AudioStreamDecoder
        // isGapless: true means DON'T flush buffer, let old audio finish
        // waitForUnpause: true means defer BASS_ChannelPlay until 'u' with sync jiffies arrives
        audioManager.startPushStreamPlayback(url: url, format: format, sampleRate: 44100, channels: 2, replayGain: replayGain, isGapless: isGapless, startTime: startTime, waitForUnpause: waitForUnpause)

        // Reset gapless flag after use
        expectingGaplessTransition = false

        // Send STMc (stream connected) - matches URL stream behavior
        os_log(.info, log: logger, "🔗 Push stream connected - sending STMc")
        client.sendStatus("STMc")

        // Send STMs only when BASS actually starts producing audio — mirrors
        // squeezelite's output.track_started. The decoder fires the
        // audioStreamDecoderDidStartPlayback delegate callback after every
        // successful BASS_ChannelPlay; that path flushes the pending flag.
        //
        // - autostart='1'/'3' (immediate play): BASS_ChannelPlay fires inside
        //   startPlayback (via startPushStreamPlayback below) → callback → flush.
        // - autostart='0'/'2' (wait-for-unpause): startPlayback early-returns,
        //   no callback yet; BASS_ChannelPlay fires later in resumePlayback or
        //   in the sync-start timer (when 'u' arrives) → callback → flush.
        //
        // Sending STMs synchronously here was wrong for both: it told the server
        // "track started" before BASS had played a single frame, which jumped
        // the controller state machine to PLAYING and broke the autostart='0'
        // unpause handshake (BUFFERING+Started → _Playing; subsequent STMl
        // dropped as _Invalid; server never issued 'u'). Sit-and-defer fixes
        // it and also closes the false-STMs hole if BASS_ChannelPlay fails.
        if !isGapless {
            pendingUnpauseSTMs = true
            os_log(.info, log: logger, "🎵 STMs deferred — will fire on actual BASS playback start (wait=%{public}s)", waitForUnpause ? "YES" : "NO")
        } else {
            os_log(.info, log: logger, "🎵 Gapless track - STMs will be sent at track boundary")
        }

        // Start periodic server time fetching for lock screen updates
        startServerTimeFetching()

        // Start the 1-second heartbeat timer (like squeezelite)
        startPlaybackHeartbeat()

        // Start radio metadata refresh poll (self-disables for non-radio streams).
        startRadioMetadataRefreshTimer()

        // Get initial metadata for new stream
        // CRITICAL: For gapless transitions, defer metadata until track boundary!
        // sendTrackStarted() will call fetchCurrentTrackMetadata() at the right time.
        // Otherwise we show next track's info while old track still plays!
        if !isGapless {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.fetchCurrentTrackMetadata()
            }
        } else {
            os_log(.info, log: logger, "🎵 Gapless - deferring metadata fetch until track boundary (sendTrackStarted)")
        }

        // Fetch server time after connection stabilizes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.fetchServerTime()
        }

        os_log(.info, log: logger, "✅ Direct stream (push mode) playback started")
    }

    func didPauseStream() {
        os_log(.info, log: logger, "⏸️ Server pause command")
        syncControllerReset(reason: "didPauseStream")

        // CRITICAL FIX: Update SimpleTimeTracker with pause state
        let currentTime = simpleTimeTracker.getCurrentTimeDouble()
        simpleTimeTracker.updateFromServer(time: currentTime, playing: false)
        
        // Normal foreground or background pause - let background handler deal with position saving
        audioManager.pause()

        // Event-gated silent-recovery unmute: now that BASS is actually paused (no audio
        // flowing), it is safe to restore DSP gain. Gating on this real pause confirmation
        // instead of a fixed timer removes the unmute-vs-playback race behind the blip.
        finishSilentRecoveryIfArmed(reason: "pause confirmed")

        stopPlaybackHeartbeat()
        stopRadioMetadataRefreshTimer()

        if !isAppInBackground {
            client.sendStatus("STMp")
        }
    }

    func didResumeStream() {
        os_log(.info, log: logger, "▶️ Server unpause command")

        // STMs flush for sync-wait tracks now happens in
        // handleDecoderDidStartPlayback (fired by the decoder when BASS_ChannelPlay
        // actually succeeds). The audioManager.play() below routes to
        // resumePlayback which triggers that callback.

        // CRITICAL FIX: Update SimpleTimeTracker with resume state
        let currentTime = simpleTimeTracker.getCurrentTimeDouble()
        simpleTimeTracker.updateFromServer(time: currentTime, playing: true)

        #if os(iOS)
        audioManager.activateAudioSession(context: .serverResume)
        #else
        audioManager.activateAudioSession()
        #endif
        audioManager.play()

        // Restart heartbeat when resumed
        startPlaybackHeartbeat()

        // Restart radio metadata refresh poll when resumed
        startRadioMetadataRefreshTimer()

        // Fetch initial metadata after resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.fetchCurrentTrackMetadata()
        }

        client.sendStatus("STMr")
    }

    func didStopStream() {
        os_log(.info, log: logger, "⏹️ Server stop command")

        audioManager.stop()

        // If a silent-recovery pause was turned into a STOP by the server, didPauseStream
        // never fires — clear the latch here too so it can't unmute a later unrelated pause.
        // (The +3.5s fallback timer would also catch it; this just closes the window sooner.)
        finishSilentRecoveryIfArmed(reason: "stop")

        // CRITICAL: Clear gapless flag - stop command means next track is manual skip, not gapless!
        // If we don't clear this, old buffered audio keeps playing after skip
        expectingGaplessTransition = false
        os_log(.info, log: logger, "🧹 Cleared gapless flag - next track will flush buffer")

        // CRITICAL FIX: Update both SimpleTimeTracker AND NowPlayingManager to stop interpolating
        updateServerTime(position: 0.0, duration: 0.0, isPlaying: false)

        // Stop periodic server time fetching
        stopServerTimeFetching()

        // Stop heartbeat when stopped
        stopPlaybackHeartbeat()

        // Stop radio metadata refresh poll
        stopRadioMetadataRefreshTimer()

        // Note: ICY metadata callbacks are handled automatically by BASS

        client.sendStatus("STMf")
    }

    // MARK: - Gapless Playback - Track Decode Complete

    /// Send STMd message when decoder completes naturally (like squeezelite DECODE_COMPLETE)
    /// This tells the server the track finished decoding and triggers next track queueing
    func sendTrackDecodeComplete() {
        let timestamp = Date()
        os_log(.error, log: logger, "✅✅✅ TRACK DECODE COMPLETE - sending STMd to server")
        os_log(.error, log: logger, "📊 Timestamp: %{public}s", timestamp.description)
        os_log(.error, log: logger, "📊 This means: All track data decoded, boundary marked, audio still playing from buffer")

        // CRITICAL: Mark gapless flag BEFORE sending STMd to prevent race condition!
        // If server responds very quickly (local network), the new STRM could arrive
        // before the next line executes, causing isGapless to be false when it should be true
        expectingGaplessTransition = true

        // Like squeezelite: decode.state = DECODE_COMPLETE → wake_controller() → sendSTAT("STMd", 0)
        client.sendStatus("STMd")

        // Server will respond with new STRM command for next track
        // With autostart=2 or 3 (wait for CONT before starting decode)
        os_log(.error, log: logger, "📊 Waiting for server to queue next track (gapless mode enabled)...")
        os_log(.error, log: logger, "📊 When playback reaches boundary → STMs will be sent → Material will update")
    }

    /// Send STMn message when decoder encounters error (like squeezelite DECODE_ERROR)
    func sendTrackDecodeError() {
        os_log(.error, log: logger, "❌ Track decode error - sending STMn to server")
        client.sendStatus("STMn")
    }

    /// Send STMs message when playback reaches track boundary (like squeezelite output.track_started)
    /// This keeps Material UI in sync with actual audio playback
    func sendTrackStarted() {
        let timestamp = Date()
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 🎯🎯🎯 SENDING STMs TO SERVER - Material UI should update NOW")
        os_log(.error, log: logger, "[BOUNDARY-DRIFT] 📊 Timestamp: %{public}s", timestamp.description)
        syncControllerReset(reason: "sendTrackStarted/STMs")

        // UNIFIED RECOVERY: Increment track index on boundary (LMS_StreamTest-6lb)
        // This works even when disconnected - ensures our local index tracks gapless transitions
        let currentIndex = UserDefaults.standard.integer(forKey: "lyrplay_recovery_index")
        UserDefaults.standard.set(currentIndex + 1, forKey: "lyrplay_recovery_index")
        os_log(.info, log: logger, "📍 Track boundary: recovery index incremented to %d", currentIndex + 1)

        // CRITICAL FIX: Reset SimpleTimeTracker to 0 when new track starts
        // This ensures lock screen shows 0:00 for the new track, not stale time from previous track
        simpleTimeTracker.updateFromServer(time: 0.0, duration: 0.0, playing: true)
        os_log(.info, log: logger, "[BOUNDARY-DRIFT] 🔄 Reset SimpleTimeTracker to 0.0 for new track start")

        // Like squeezelite output.c:155 - output.track_started = true → send STMs
        // This updates Material to show the track that's NOW PLAYING (not just queued)
        client.sendStatus("STMs")

        // CRITICAL FIX: Delay metadata fetch to avoid race condition with server
        // Server needs time to process STMs before we query metadata, otherwise it may
        // return stale data (previous track) if metadata query arrives before STMs
        os_log(.info, log: logger, "[BOUNDARY-DRIFT] 🔄 Delaying metadata fetch 500ms to let server process STMs first")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            os_log(.info, log: self.logger, "[BOUNDARY-DRIFT] 🔄 Now fetching metadata after STMs processing delay")
            self.fetchCurrentTrackMetadata()
        }

        os_log(.error, log: logger, "[BOUNDARY-DRIFT] ✅ STMs sent + time reset + metadata refresh scheduled - lock screen should update in 500ms")
    }

    /// Send STMl (buffer loaded) status to server (PHASE 7.7)
    /// This signals that buffer has reached threshold and player is ready for synchronized start
    func sendBufferLoaded() {
        os_log(.info, log: logger, "📊 Sending STMl (buffer loaded) to server")
        // Like squeezelite: buffer reaches threshold → send STMl
        // This allows server to check if ALL players are ready and transition from WAITING_TO_SYNC
        client.sendStatus("STMl")
    }

    func getCurrentAudioTime() -> Double {
        // IMPORTANT: This is for SlimProto status reporting - use AudioPlayer time
        // AudioPlayer time resets to 0 for new tracks, which is what SlimProto expects
        // For recovery operations, use getCurrentInterpolatedTime() instead
        return audioManager.getAudioPlayerTimeForFallback()
    }

    func hasActiveStream() -> Bool {
        // Check if we have an active BASS stream (not stale after reconnect)
        // This includes both URL streams (audioPlayer) and push streams (streamDecoder)
        let playerState = audioManager.getPlayerState()
        let hasPushStream = audioManager.hasPushStream()
        return playerState != "No Stream" || hasPushStream
    }

    func didReceiveStatusRequest() {
        // Server is asking "are you alive?" - just confirm we're here
        // Don't confuse it with local player timing information
        
        let statusCode: String
        if commandHandler.streamState == "Paused" {
            statusCode = "STMp"  // We're paused
        } else {
            statusCode = "STMt"  // We're playing/ready
        }
        
        client.sendStatus(statusCode)
        
        // Record that we responded (shows connection is alive)
        connectionManager.recordHeartbeatResponse()
        
        //os_log(.debug, log: logger, "📍 Responded to server status request with %{public}s", statusCode)
    }
    
    
}

// MARK: - Material-Style Time Tracking (Simplified)
extension SlimProtoCoordinator {

    // MARK: - Player Synchronization: Jiffies Epoch Tracking

    /// Track jiffies epoch for player synchronization (multi-room audio)
    /// This maintains agreement on time base between player and server for synchronized playback
    private func trackJiffiesEpoch(jiffies: UInt32, serverTimestamp: TimeInterval) {
        // Convert jiffies (milliseconds) to seconds for comparison with server time
        let jiffiesTime = Double(jiffies) / 1000.0

        // Calculate offset between server time and local jiffies time
        let offset = serverTimestamp - jiffiesTime

        // Adjust epoch if we get a better estimate or handle wrap-around
        // Update if offset is significantly different (>50s) or if this is first measurement
        if jiffiesEpoch == 0 || offset < jiffiesEpoch || offset - jiffiesEpoch > 50 {
            jiffiesEpoch = offset
            os_log(.info, log: logger, "🔄 Jiffies epoch updated: %.3f (server: %.3f, jiffies: %.3f)",
                   jiffiesEpoch, serverTimestamp, jiffiesTime)
        }

        // Track drift for sync corrections (like squeezelite)
        let drift = offset - jiffiesEpoch
        jiffiesOffsetList.insert(drift, at: 0)

        // Keep only last 8 measurements for drift calculation
        if jiffiesOffsetList.count > 8 {
            jiffiesOffsetList.removeLast()
        }

        // Log drift if significant (for debugging sync issues)
        if abs(drift) > 0.010 {  // Log if drift > 10ms
            os_log(.debug, log: logger, "📊 Sync drift: %.3f ms (offset: %.3f, epoch: %.3f)",
                   drift * 1000, offset, jiffiesEpoch)
        }
    }

    /// Get current jiffies (milliseconds since app start)
    /// This is the player's local timer that gets synchronized with server
    private func gettime_ms() -> UInt32 {
        // Use system uptime in milliseconds (monotonic, doesn't change with clock adjustments)
        // Wraps at UInt32.max (~49.7 days uptime) like squeezelite's gettime_ms —
        // trackJiffiesEpoch re-syncs the epoch after a wrap
        return SlimProtoClient.jiffies(uptimeSeconds: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Sync Group Persistence

    /// Parse serv packet and extract sync group ID for multi-room persistence
    private func handleServPacket(_ payload: Data) {
        // serv packet structure (from SlimProto documentation):
        // - Server IP (4 bytes)
        // - HTTP port (2 bytes)
        // - CLI port (2 bytes)
        // - Sync group ID (10 bytes) - THIS IS WHAT WE NEED
        // Total minimum: 18 bytes

        guard payload.count >= 18 else {
            os_log(.error, log: logger, "⚠️ serv packet too short: %d bytes (expected >= 18)", payload.count)
            return
        }

        // Extract sync group ID from bytes 8-17 (10 bytes)
        let syncGroup = payload.subdata(in: 8..<18)

        // Check if sync group is all zeros (no sync group)
        let isEmptySyncGroup = syncGroup.allSatisfy { $0 == 0 }

        if isEmptySyncGroup {
            // No sync group - clear stored value
            os_log(.info, log: logger, "🔗 No sync group (player not synced)")
            syncGroupID = nil
            settings.clearSyncGroupID()
        } else {
            // Store sync group ID
            os_log(.info, log: logger, "🔗 Sync group ID received: %{public}s",
                   syncGroup.map { String(format: "%02x", $0) }.joined(separator: ":"))
            syncGroupID = syncGroup
            settings.saveSyncGroupID(syncGroup)
        }
    }

    /// Update current server time from actual server responses (Material-style approach)
    func updateServerTime(position: Double, duration: Double = 0.0, isPlaying: Bool) {
        // SIMPLIFIED: Update SimpleTimeTracker with Material-style approach
        simpleTimeTracker.updateFromServer(time: position, duration: duration, playing: isPlaying)

        // Update NowPlayingManager with fresh server time
        audioManager.getNowPlayingManager().updateFromSlimProto(
            currentTime: position,
            duration: duration > 0 ? duration : simpleTimeTracker.getTrackDuration(),
            isPlaying: isPlaying
        )

        // Too spammy - uncomment only for debugging server time sync
        // os_log(.debug, log: logger, "📍 Updated server time: %.2f (playing: %{public}s) [Material-style]",
        //        position, isPlaying ? "YES" : "NO")
    }
    
    /// Fetch actual server time via JSON-RPC (not audio player time)
    func fetchServerTime() {
        guard !settings.activeServerHost.isEmpty else {
            os_log(.debug, log: logger, "⏱️ fetchServerTime: No active server host")
            return
        }

        // Too spammy - removed, throttled log added to parseServerTimeResponse instead

        let playerID = settings.playerMACAddress
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                ["status", "-", "1", "tags:u,d,t,K,c"]
            ]
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            return
        }
        
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        guard let url = URL(string: "http://\(host):\(webPort)/jsonrpc.js") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")

        // Add HTTP Basic Authentication if configured
        if let authHeader = settings.generateAuthHeader() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            os_log(.debug, log: logger, "🔐 Added auth to JSON-RPC request (user: %{public}s)", settings.activeServerUsername)
        }

        request.httpBody = jsonData
        request.timeoutInterval = 5.0
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.parseServerTimeResponse(data: data, error: error)
            }
        }.resume()
    }
    
    /// Parse JSON-RPC response to extract real server time
    private func parseServerTimeResponse(data: Data?, error: Error?) {
        guard let data = data, error == nil else {
            if let error = error {
                os_log(.error, log: logger, "⏱️ Server time fetch FAILED: %{public}s", error.localizedDescription)
            } else {
                os_log(.error, log: logger, "⏱️ Server time fetch FAILED: No data received")
            }
            return
        }

        // Too spammy - uncomment only for debugging server time responses
        // os_log(.debug, log: logger, "⏱️ Server time response received, parsing...")

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any] else {
                os_log(.error, log: logger, "⏱️ Server time parse FAILED: Invalid JSON structure")
                return
            }
            
            // Extract REAL server time from server response
            let serverTime = result["time"] as? Double ?? 0.0
            let duration = result["duration"] as? Double ?? 0.0
            let mode = result["mode"] as? String ?? "stop"
            let isPlaying = (mode == "play")

            // PHASE 1: Track jiffies epoch for player synchronization
            // Get current local jiffies (milliseconds since app start)
            let currentJiffies = gettime_ms()
            // Update epoch tracking with server timestamp and local jiffies
            trackJiffiesEpoch(jiffies: currentJiffies, serverTimestamp: serverTime)

            // Update our time tracking with REAL server time
            updateServerTime(position: serverTime, duration: duration, isPlaying: isPlaying)

            // Throttle logging to every 10 seconds to reduce spam
            let shouldLog: Bool
            if let lastLog = lastServerTimeFetchLog {
                shouldLog = Date().timeIntervalSince(lastLog) >= 10.0
            } else {
                shouldLog = true
            }

            // NOTE: Position saving moved to NowPlayingManager.updateNowPlayingTime() (LMS_StreamTest-6lb)
            // NowPlayingManager's timer never stops, so position is saved even when disconnected

            // UNIFIED RECOVERY: Sync track index from server when connected (LMS_StreamTest-6lb)
            // This ensures our local index is authoritative when server tells us current track
            if let serverIndex = result["playlist_cur_index"] as? Int {
                UserDefaults.standard.set(serverIndex, forKey: "lyrplay_recovery_index")
            } else if let serverIndexString = result["playlist_cur_index"] as? String,
                      let serverIndex = Int(serverIndexString) {
                UserDefaults.standard.set(serverIndex, forKey: "lyrplay_recovery_index")
            }

            if shouldLog {
                os_log(.info, log: logger, "⏱️ Server time: %.2f (playing: %{public}s)",
                       serverTime, isPlaying ? "YES" : "NO")
                lastServerTimeFetchLog = Date()
            }
            
        } catch {
            os_log(.error, log: logger, "❌ Failed to parse server time response: %{public}s", error.localizedDescription)
        }
    }
    
    /// Get current interpolated time (Material-style approach only)
    func getCurrentInterpolatedTime() -> (time: Double, playing: Bool) {
        // SIMPLIFIED: Use only SimpleTimeTracker (Material-style approach)
        return simpleTimeTracker.getCurrentTime()
    }

    /// Toggle play/pause for SwiftUI HW handlers (.onPlayPauseCommand on tvOS).
    ///
    /// Uses the synchronous `commandHandler.isPausedByLockScreen` flag rather than
    /// `getCurrentInterpolatedTime().playing`. The latter is driven by server STAT
    /// updates and lags the user's last action by one server roundtrip — fast HW
    /// presses see stale state and send the wrong command, producing the
    /// "press-twice-to-resume" bug on tvOS Search/Queue views (hardware-verified
    /// 2026-05-07). The flag flips the moment we send pause/play locally.
    func toggleLockScreenPlayPause() {
        if commandHandler.isPausedByLockScreen {
            sendLockScreenCommand("play")
        } else {
            sendLockScreenCommand("pause")
        }
    }
    
    /// Get current time for position saving
    func getCurrentTimeForSaving() -> Double {
        let (time, _) = getCurrentInterpolatedTime()
        return time
    }
    
    #if os(iOS)
    /// Set WebView reference for Material UI refresh
    func setWebView(_ webView: WKWebView) {
        self.webView = webView
        os_log(.info, log: logger, "✅ WebView reference set for Material UI refresh")
    }
    #endif
    
    /// Public method to refresh Material UI (can be called externally)
    /// Start periodic server time fetching
    func startServerTimeFetching() {
        // CRITICAL: Timer must be created on main thread to ensure it has a RunLoop
        // Background DispatchQueues don't have RunLoops, so timers won't fire repeatedly
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Stop any existing timer directly (not via async method to avoid race condition)
            self.serverTimeTimer?.invalidate()
            self.serverTimeTimer = nil

            // Fetch immediately
            self.fetchServerTime()

            // Start periodic timer (every 3 seconds for responsive lock screen)
            // MUST be on main thread RunLoop to fire repeatedly
            self.serverTimeTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
                self?.fetchServerTime()
            }

            os_log(.debug, log: self.logger, "🔄 Started periodic server time fetching (on main thread)")
        }
    }
    
    /// Stop periodic server time fetching
    func stopServerTimeFetching() {
        // Also ensure stop happens on main thread where timer was created
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.serverTimeTimer?.invalidate()
            self.serverTimeTimer = nil
            os_log(.debug, log: self.logger, "⏹️ Stopped periodic server time fetching")
        }
    }
}

// MARK: - Enhanced Lock Screen Integration with SlimProto Connection Fix
extension SlimProtoCoordinator {
    
    func sendLockScreenCommand(_ command: String) {
        os_log(.info, log: logger, "🔒 Lock Screen command: %{public}s", command)

        // Save position on pause commands (creates save point for future recovery)
        if command.lowercased() == "pause" {
            // Local save first (instant, survives network transitions like CarPlay disconnect)
            let position = getCurrentTimeForSaving()
            if position > 0 {
                UserDefaults.standard.set(position, forKey: "lyrplay_recovery_position")
                UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
                UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "lyrplay_recovery_index"), forKey: "lyrplay_recovery_index")
            }
            // Server roundtrip overwrites with authoritative data if reachable
            saveCurrentPositionForRecovery()
            os_log(.info, log: logger, "💾 Saved position on pause command for future recovery")
        }

        #if os(iOS)
        // CRITICAL: Always activate audio session for lock screen commands (ensures iOS readiness)
        let context: PlaybackSessionController.ActivationContext = command.lowercased() == "play" ? .userInitiatedPlay : .backgroundRefresh
        audioManager.activateAudioSession(context: context)
        #else
        audioManager.activateAudioSession()
        #endif

        // Lock screen PLAY: Use duration-based recovery (only reconnect if long background)
        // For PAUSE/other: Just send command normally (no need to disconnect)

        if command.lowercased() == "play" {
            // Check background duration - only reconnect/recover if backgrounded > 45 seconds.
            // Reads in-memory bgTime, then falls back to UserDefaults if iOS killed the process.
            if let duration = getBackgroundDuration() {
                os_log(.info, log: logger, "🔒 Lock screen PLAY: Backgrounded for %.1f seconds", duration)

                if duration > 45 {
                    // Long background (> 45s) - reconnect and recover position
                    os_log(.info, log: logger, "🔄 Lock screen PLAY: Long background (%.1fs) - setting lockScreen trigger", duration)

                    // UNIFIED RECOVERY: Set trigger and let slimProtoDidConnect handle recovery (LMS_StreamTest-6lb)
                    pendingRecoveryTrigger = .lockScreen

                    // Trust BASS to auto-manage stream state during reconnection
                    // BASS handles iOS audio session activation/deactivation automatically
                    connect()
                    // slimProtoDidConnect will call handlePendingRecovery()
                } else {
                    // Brief background (< 45s) - just send play command (fast!)
                    os_log(.info, log: logger, "🔒 Lock screen PLAY: Brief background (%.1fs) - sending play command", duration)
                    sendJSONRPCCommand(command)
                }
            } else {
                // No background time tracked - just send play command
                os_log(.info, log: logger, "🔒 Lock screen PLAY: No background time - sending play command")
                sendJSONRPCCommand(command)
            }
        } else {
            // PAUSE or other commands: Send normally without forced reconnect
            // This prevents disconnecting unnecessarily and keeps server interface in sync

            if !connectionManager.connectionState.isConnected {
                os_log(.info, log: logger, "🔄 Lock screen %{public}s: Not connected, reconnecting", command)
                connect()

                // Wait briefly for connection
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.sendJSONRPCCommand(command)
                }
            } else {
                // Already connected - send command immediately
                os_log(.info, log: logger, "🔒 Lock screen %{public}s: Sending on existing connection", command)
                sendJSONRPCCommand(command)
            }
        }
        
        // Track lock screen pause state
        if command.lowercased() == "pause" {
            commandHandler.isPausedByLockScreen = true
        }
    }

    private func sendJSONRPCCommand(_ command: String, retryCount: Int = 0) {
        // CRITICAL FIX: For pause commands, get current server position FIRST
        if command.lowercased() == "pause" {
            os_log(.info, log: logger, "🔒 Pause command - getting current server position first")
            
            // Wait a moment for sync to complete, then continue with normal pause logic
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Now do the normal pause command processing
                self.sendNormalJSONRPCCommand("pause", retryCount: retryCount)
            }
            return
        }
        
        // For non-pause commands, process normally
        sendNormalJSONRPCCommand(command, retryCount: retryCount)
    }

    // ADD this new method right after the sendJSONRPCCommand method:
    private func sendNormalJSONRPCCommand(_ command: String, retryCount: Int = 0) {
        let playerID = settings.playerMACAddress
        
        var jsonRPCCommand: [String: Any]
        
        switch command.lowercased() {
        case "pause":
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["pause", "1"]]
            ]
        case "play":
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["pause", "0"]]
            ]
        case "stop":
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["stop"]]
            ]
        case "next":
            // CRITICAL: Prevent track end detection during manual skip
            commandHandler.startSkipProtection()
            
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlist", "index", "+1"]]
            ]
        case "previous":
            // CRITICAL: Prevent track end detection during manual skip
            commandHandler.startSkipProtection()
            
            jsonRPCCommand = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlist", "index", "-1"]]
            ]
        default:
            os_log(.error, log: logger, "Unknown JSON-RPC command: %{public}s", command)
            return
        }
        
        sendJSONCommand(jsonRPCCommand, command: command, retryCount: retryCount)
    }
    
    private func sendJSONCommand(_ jsonRPC: [String: Any], command: String, retryCount: Int = 0) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create JSON-RPC command for %{public}s", command)
            return
        }
        
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        guard let url = URL(string: "http://\(host):\(webPort)/jsonrpc.js") else {
            os_log(.error, log: logger, "Invalid server URL for JSON-RPC")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 10.0

        // Add HTTP Basic Authentication if configured
        if let authHeader = settings.generateAuthHeader() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self.logger, "JSON-RPC %{public}s failed: %{public}s", command, error.localizedDescription)
                    
                    if retryCount < 2 && (command.lowercased() == "play" || command.lowercased() == "pause") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.sendJSONRPCCommand(command, retryCount: retryCount + 1)
                        }
                    }
                } else {
                    os_log(.info, log: self.logger, "✅ JSON-RPC %{public}s command sent successfully", command)
                    
                    // CRITICAL: For play commands, ensure we have a working SlimProto connection
                    if command.lowercased() == "play" {
                        self.ensureSlimProtoConnection()
                    }
                    
                    // Server time sync continues automatically - no additional action needed
                    // Note: Metadata will be refreshed automatically when server sends new stream
                }
            }
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Sent JSON-RPC %{public}s command to LMS", command)
    }
    
    
    
    
    // Direct JSON-RPC command sender for preference testing and CarPlay services
    public func sendJSONRPCCommandDirect(_ jsonRPC: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        os_log(.debug, log: logger, "🌐 Sending JSON-RPC command: %{public}s", String(describing: jsonRPC))

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "❌ Failed to create JSON-RPC command")
            completion([:])
            return
        }

        // CRITICAL FIX: Use direct LMS endpoint instead of Material's /material/jsonrpc.js
        // Material endpoint can apply commands to wrong player based on Material UI session state
        // Direct endpoint ensures player MAC in params[0] is always respected
        let urlString = "http://\(settings.activeServerHost):\(settings.activeServerWebPort)/jsonrpc.js"
        os_log(.debug, log: logger, "🌐 JSON-RPC URL: %{public}s", urlString)
        
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "❌ Invalid JSON-RPC URL: %{public}s", urlString)
            completion([:])
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")

        // Add HTTP Basic Authentication if configured
        if let authHeader = settings.generateAuthHeader() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            os_log(.debug, log: logger, "🔐 Added auth to JSON-RPC request (user: %{public}s)", settings.activeServerUsername)
        }

        request.httpBody = jsonData
        request.timeoutInterval = 5.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: self.logger, "❌ JSON-RPC request failed: %{public}s", error.localizedDescription)
                completion([:])
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                os_log(.debug, log: self.logger, "🌐 JSON-RPC response status: %d", httpResponse.statusCode)
            }

            guard let data = data else {
                os_log(.error, log: self.logger, "❌ No data received from JSON-RPC request")
                completion([:])
                return
            }

            do {
                if let jsonResult = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    os_log(.debug, log: self.logger, "✅ JSON-RPC response: %{public}s", String(describing: jsonResult))
                    completion(jsonResult)
                } else {
                    os_log(.error, log: self.logger, "❌ Invalid JSON-RPC response format")
                    completion([:])
                }
            } catch {
                os_log(.error, log: self.logger, "❌ Failed to parse JSON-RPC response: %{public}s", error.localizedDescription)
                completion([:])
            }
        }
        
        task.resume()
    }

    /// Toggles shuffle mode through LMS's 3-state cycle: off→songs→albums→off
    /// Called by CarPlay shuffle button and MPRemoteCommandCenter
    /// - Parameter completion: Optional callback with new shuffle mode (0=off, 1=songs, 2=albums)
    public func toggleShuffleMode(completion: ((Int) -> Void)? = nil) {
        let playerID = settings.playerMACAddress

        // Query current shuffle state
        let statusCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["status", "-", 1, "tags:"]]
        ]

        os_log(.info, log: logger, "🔀 Shuffle toggle requested...")

        sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
            guard let self = self else { return }

            let currentShuffle: Int
            if let result = response["result"] as? [String: Any],
               let shuffleMode = result["playlist shuffle"] as? Int {
                currentShuffle = shuffleMode
            } else {
                currentShuffle = 0
                os_log(.info, log: self.logger, "⚠️ Could not read shuffle state, defaulting to 0")
            }

            // Toggle to next state (0→1→2→0)
            let newMode = PlaylistModeCycle.nextShuffle(currentShuffle)

            os_log(.info, log: self.logger, "🔀 Shuffle: %d → %d", currentShuffle, newMode)

            // Send shuffle command
            let shuffleCommand: [String: Any] = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlist", "shuffle", newMode]]
            ]

            self.sendJSONRPCCommandDirect(shuffleCommand) { [weak self] shuffleResponse in
                guard let self = self else { return }

                if !shuffleResponse.isEmpty {
                    os_log(.info, log: self.logger, "✅ Shuffle mode set to %d", newMode)

                    #if os(iOS)
                    // Update MPRemoteCommandCenter for lock screen/Control Center
                    DispatchQueue.main.async {
                        let shuffleType: MPShuffleType = newMode == 1 ? .items : (newMode == 2 ? .collections : .off)
                        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = shuffleType
                        os_log(.info, log: self.logger, "🔀 Remote command center updated: %{public}s",
                               shuffleType == .off ? "off" : (shuffleType == .items ? "songs" : "albums"))
                    }
                    #endif

                    // Notify CarPlay to update button icon
                    completion?(newMode)
                }
            }
        }
    }

    /// Toggles repeat mode through LMS's 3-state cycle: off→all→one→off
    /// (Apple Music ordering). Called by the tvOS Now Playing repeat button (w53).
    /// Mirrors toggleShuffleMode minus the MPRemoteCommandCenter update — no
    /// iOS caller registers a repeat remote command yet.
    /// - Parameter completion: Optional callback with the new repeat mode —
    ///   value legend (not cycle order): 0=off, 2=all, 1=one
    public func toggleRepeatMode(completion: ((Int) -> Void)? = nil) {
        let playerID = settings.playerMACAddress

        // Query current repeat state
        let statusCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["status", "-", 1, "tags:"]]
        ]

        os_log(.info, log: logger, "🔁 Repeat toggle requested...")

        sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
            guard let self = self else { return }

            let currentRepeat: Int
            if let result = response["result"] as? [String: Any],
               let repeatMode = result["playlist repeat"] as? Int {
                currentRepeat = repeatMode
            } else {
                currentRepeat = 0
                os_log(.info, log: self.logger, "⚠️ Could not read repeat state, defaulting to 0")
            }

            let newMode = PlaylistModeCycle.nextRepeat(currentRepeat)
            os_log(.info, log: self.logger, "🔁 Repeat: %d → %d", currentRepeat, newMode)

            let repeatCommand: [String: Any] = [
                "id": 1,
                "method": "slim.request",
                "params": [playerID, ["playlist", "repeat", newMode]]
            ]

            self.sendJSONRPCCommandDirect(repeatCommand) { [weak self] repeatResponse in
                guard let self = self else { return }
                if !repeatResponse.isEmpty {
                    os_log(.info, log: self.logger, "✅ Repeat mode set to %d", newMode)
                    completion?(newMode)
                }
            }
        }
    }

    /// Reads the player's current repeat + shuffle modes in one status query.
    /// tvOS Now Playing syncs its button state with this on appear and on track
    /// change (same query CarPlay's syncShuffleButtonWithServer fires for
    /// shuffle alone). Completion runs on the main thread.
    ///
    /// On a failed/unparseable query the completion is NOT invoked — callers
    /// keep their last known state. Fabricating (0, 0) here would paint mode
    /// buttons "off" during a network blip and make the next tap cycle from
    /// the wrong starting point.
    /// - Parameter completion: (repeatMode, shuffleMode) per LMS values
    ///   (repeat 0=off, 2=all, 1=one; shuffle 0=off, 1=songs, 2=albums).
    public func fetchPlaylistModes(completion: @escaping (Int, Int) -> Void) {
        let statusCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["status", "-", 1, "tags:"]]
        ]

        sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
            guard let result = response["result"] as? [String: Any] else {
                if let self {
                    os_log(.info, log: self.logger, "⚠️ Could not read playlist modes — keeping last known state")
                }
                return
            }
            let repeatMode = result["playlist repeat"] as? Int ?? 0
            let shuffleMode = result["playlist shuffle"] as? Int ?? 0
            DispatchQueue.main.async {
                completion(repeatMode, shuffleMode)
            }
        }
    }

    // MARK: - Start DSTM from current track (GH #85)
    //
    // Provider-agnostic "Don't Stop The Music" trigger. CarPlay queues whole
    // albums, so the queue never gets short enough for DSTM (MIN_TRACKS_LEFT=2)
    // to fire. This clears the upcoming tracks so the CURRENT track becomes the
    // queue tail; the player's configured DSTM provider (LastMix, Bliss,
    // RandomPlay, RatingsLight, …) then auto-appends similar tracks seeded from
    // where you are. Works for ANY provider, unlike a Bliss-specific trackinfo
    // mix (most DSTM providers expose no per-track "create mix" action).
    //
    // Flow (all JSON-RPC; completions fire on a URLSession background thread —
    // CarPlay callers must marshal UI work to main):
    //
    //   status - 1 tags:  ──▶ playlist_cur_index + playlist_tracks
    //        │
    //        ▼
    //   playlist delete <i>  for i = last … cur+1   (high→low; index-stable)
    //        │
    //        ▼
    //   DSTM provider auto-appends within ~10s
    //
    // Verified live against 192.168.1.8 on 2026-05-30: deleting the tail of a
    // 13-track album left the playing track intact (mode=play), and with a
    // provider set the short queue auto-grew 1→10 tracks in ~10s.
    //
    // DSTM_PROVIDER_PREF is "0"/"Disabled" when DSTM is off — clearing the tail
    // then would just end playback, so the button is gated on this.
    private static let dstmProviderPref = "plugin.dontstopthemusic:provider"

    /// Whether DSTM is enabled for this player (a provider other than Disabled).
    /// Gates the CarPlay "Keep Playing" button so it never strands the user with
    /// a queue that just stops.
    public func probeDSTMEnabled(completion: @escaping (Bool) -> Void) {
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress,
                       ["playerpref", Self.dstmProviderPref, "?"]]
        ]
        sendJSONRPCCommandDirect(cmd) { [weak self] response in
            let provider = (response["result"] as? [String: Any])?["_p2"]
            let value = (provider as? String) ?? (provider as? Int).map(String.init)
            let enabled = value != nil && value != "0" && value != ""
            if let self = self {
                os_log(.info, log: self.logger, "🎚️ DSTM provider: %{public}s (enabled=%{public}s)",
                       value ?? "nil", enabled ? "yes" : "no")
            }
            completion(enabled)
        }
    }

    /// Trigger DSTM from the currently-playing track by clearing every queued
    /// track after it. The player's DSTM provider then continues seeded from the
    /// current track. `completion(true)` once the tail is cleared (or there was
    /// nothing to clear); `false` if the current state couldn't be read.
    public func startDSTMFromCurrentTrack(completion: ((Bool) -> Void)? = nil) {
        let playerID = settings.playerMACAddress
        let statusCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["status", "-", 1, "tags:"]]
        ]
        sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
            guard let self = self else { completion?(false); return }
            // both fields can arrive as Int or String depending on LMS build
            func intVal(_ any: Any?) -> Int? {
                (any as? Int) ?? (any as? String).flatMap(Int.init)
            }
            guard let result = response["result"] as? [String: Any],
                  let total = intVal(result["playlist_tracks"]),
                  let current = intVal(result["playlist_cur_index"]) else {
                os_log(.info, log: self.logger, "🎚️ DSTM: could not read queue state")
                completion?(false)
                return
            }
            let lastIndex = total - 1
            if lastIndex <= current {
                os_log(.info, log: self.logger, "🎚️ DSTM: queue already at tail (cur=%d, total=%d) — provider will continue", current, total)
                completion?(true)
                return
            }
            os_log(.info, log: self.logger, "🎚️ DSTM: clearing tail, deleting indices %d…%d (cur=%d)", current + 1, lastIndex, current)
            // Delete high→low so each index stays valid as lower ones don't shift.
            self.deletePlaylistTail(playerID: playerID, index: lastIndex, stopAt: current, completion: completion)
        }
    }

    /// Recursively delete one queue index at a time, high→low, down to `stopAt`
    /// (exclusive). Sequential because each `playlist delete` is its own request
    /// and the JSON-RPC completion lands on a background thread.
    private func deletePlaylistTail(playerID: String, index: Int, stopAt: Int,
                                    completion: ((Bool) -> Void)?) {
        guard index > stopAt else { completion?(true); return }
        let deleteCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playlist", "delete", index]]
        ]
        sendJSONRPCCommandDirect(deleteCommand) { [weak self] _ in
            guard let self = self else { completion?(true); return }
            self.deletePlaylistTail(playerID: playerID, index: index - 1,
                                    stopAt: stopAt, completion: completion)
        }
    }

    /// Sends pause command to server with confirmation and retry logic
    /// Used for critical pause operations (CarPlay disconnect) where we must ensure server received it
    /// - Parameters:
    ///   - maxRetries: Maximum number of retry attempts (default 3)
    ///   - completion: Optional callback with success/failure result
    public func sendPauseWithConfirmation(maxRetries: Int = 3, completion: ((Bool) -> Void)? = nil) {
        os_log(.info, log: logger, "⏸️ Sending pause with confirmation (max retries: %d)", maxRetries)

        // Send initial pause command
        sendLockScreenCommand("pause")

        // After 1 second, verify server is paused
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.verifyServerPaused(retriesRemaining: maxRetries, completion: completion)
        }
    }

    /// Seeks to an absolute position within the current track via LMS `playlist time` JSON-RPC.
    /// Server-side seek; works across all formats including FLAC (via MobileTranscode plugin).
    public func seek(toSeconds seconds: Double) {
        let clamped = max(0.0, seconds)
        let seekCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["time", String(format: "%.2f", clamped)]]
        ]
        os_log(.info, log: logger, "⏩ Seek to %.2f seconds", clamped)
        sendJSONRPCCommandDirect(seekCommand) { _ in }
    }

    /// Verifies server is in paused state, retries pause command if not
    private func verifyServerPaused(retriesRemaining: Int, completion: ((Bool) -> Void)?) {
        let playerID = settings.playerMACAddress
        let statusCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["status", "-", 1, "tags:"]]
        ]

        sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
            guard let self = self else { return }

            if let result = response["result"] as? [String: Any],
               let mode = result["mode"] as? String {

                if mode == "pause" || mode == "stop" {
                    os_log(.info, log: self.logger, "✅ Server confirmed paused (mode: %{public}s)", mode)
                    completion?(true)
                    return
                }

                os_log(.info, log: self.logger, "⚠️ Server mode is '%{public}s', not paused", mode)
            } else {
                os_log(.info, log: self.logger, "⚠️ Could not read server status")
            }

            // Server not paused - retry if we have attempts left
            if retriesRemaining > 0 {
                os_log(.info, log: self.logger, "🔄 Retrying pause command (%d attempts left)", retriesRemaining)

                // Send pause command again
                self.sendLockScreenCommand("pause")

                // Wait and verify again with exponential backoff
                let delay = 1.5 + Double(3 - retriesRemaining) * 0.5  // 1.5s, 2.0s, 2.5s
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    self.verifyServerPaused(retriesRemaining: retriesRemaining - 1, completion: completion)
                }
            } else {
                os_log(.error, log: self.logger, "❌ Failed to confirm server pause after all retries")
                completion?(false)
            }
        }
    }

    // CRITICAL: Ensure SlimProto connection for audio streaming
    private func ensureSlimProtoConnection() {
        os_log(.info, log: logger, "🔧 Ensuring SlimProto connection for audio streaming...")
        
        if !connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "🔄 SlimProto not connected - reconnecting for audio stream")
            connect()
            
            // Monitor connection establishment
            var waitTime = 0
            let connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                waitTime += 1
                
                if self.connectionManager.connectionState.isConnected {
                    os_log(.info, log: self.logger, "✅ SlimProto connection established for audio stream")
                    timer.invalidate()
                    
                    // Send status to activate audio streaming
                    self.client.sendStatus("STMt")
                    
                    // Start server time sync for position tracking
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        // Server time sync will continue automatically
                    }
                    
                } else if waitTime >= 15 {
                    os_log(.error, log: self.logger, "❌ SlimProto connection failed - audio may not work")
                    timer.invalidate()
                }
            }
        } else {
            os_log(.info, log: logger, "✅ SlimProto already connected")
            
            // Send heartbeat to ensure connection is working
            client.sendStatus("STMt")
            
            // Trigger server time sync
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                // Server time sync will continue automatically
            }
        }
    }
}


// MARK: - Metadata Integration
extension SlimProtoCoordinator {
    
    private func fetchCurrentTrackMetadata() {
        let playerID = settings.playerMACAddress

        // Stamp this fetch. The response is only applied if it's still the newest
        // one we've seen succeed (see lastAppliedMetadataSeq in parseTrackMetadata).
        metadataFetchSeq += 1
        let seq = metadataFetchSeq

        // SIMPLIFIED: Use Material skin's minimal tag set for efficiency
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                [
                    "status", "-", "1",
                    // Material skin tags: basic metadata + artwork + streaming info
                    "tags:cdegilopqrstuyAABEGIKNPSTV"
                ]
            ]
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create enhanced metadata request")
            return
        }
        
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        var request = URLRequest(url: URL(string: "http://\(host):\(webPort)/jsonrpc.js")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0

        // Add HTTP Basic Authentication if configured
        if let authHeader = settings.generateAuthHeader() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: self.logger, "Enhanced metadata request failed: %{public}s", error.localizedDescription)
                return
            }
            
            guard let data = data else {
                os_log(.error, log: self.logger, "No enhanced metadata received")
                return
            }

            self.parseTrackMetadata(data: data, seq: seq)
        }
        
        task.resume()
        os_log(.debug, log: logger, "🌐 Requesting enhanced track metadata")
    }
    
    /// The flattened result of one metadata response, ready to apply. Decoupling
    /// parse (JSON → struct) from apply (struct → managers) lets the last-write-wins
    /// guard be unit-tested with crafted seq values and no network/JSON.
    struct ParsedTrackMetadata {
        let title: String
        let artist: String
        let album: String
        let duration: Double?          // nil = preserve existing
        let bitrate: String?           // nil = LMS has no bitrate for this source
        let artworkURL: String?        // nil = no artwork (clears the cover)
        let playlistIndex: Int?        // nil = position not reported this response
        let playlistTracks: Int?
    }

    // SIMPLIFIED: parseTrackMetadata method using Material skin approach
    private func parseTrackMetadata(data: Data, seq: Int) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let loop = result["playlist_loop"] as? [[String: Any]],
               let firstTrack = loop.first {

                // SIMPLIFIED: Use Material skin's straightforward metadata approach
                let trackTitle = firstTrack["title"] as? String ?? firstTrack["track"] as? String ?? "LyrPlay"
                let trackArtist = firstTrack["artist"] as? String ?? firstTrack["albumartist"] as? String ?? "Unknown Artist"
                let trackAlbum = firstTrack["album"] as? String ?? firstTrack["remote_title"] as? String ?? "Lyrion Music Server"

                // CRITICAL FIX: Only update duration if server explicitly provides it (Material skin approach)
                let serverDuration = firstTrack["duration"] as? Double

                // LMS-reported bitrate (the `r` tag — a pretty string like
                // "850kbps"). Authoritative; BASS's own bitrate is unreliable
                // for these decoder streams. nil for sources LMS has no
                // bitrate for (some remote streams).
                let trackBitrate = (firstTrack["bitrate"] as? String).flatMap { $0.isEmpty ? nil : $0 }

                // SIMPLIFIED: Basic artwork detection
                var artworkURL: String? = nil
                if let artwork = firstTrack["artwork_url"] as? String, !artwork.isEmpty {
                    artworkURL = artwork.hasPrefix("http") ? artwork : "http://\(settings.activeServerHost):\(settings.activeServerWebPort)\(artwork)"
                } else if let coverid = firstTrack["coverid"] as? String, !coverid.isEmpty, coverid != "0" {
                    artworkURL = "http://\(settings.activeServerHost):\(settings.activeServerWebPort)/music/\(coverid)/cover.jpg"
                }

                // Inject credentials for password-protected LMS servers
                if let url = artworkURL {
                    artworkURL = settings.injectCredentialsIntoURL(url)
                }

                // Log final metadata result
                os_log(.info, log: logger, "[BOUNDARY-DRIFT] 🎵 Material-style: '%{public}s' by %{public}s%{public}s",
                       trackTitle, trackArtist, artworkURL != nil ? " [artwork]" : "")

                let parsed = ParsedTrackMetadata(
                    title: trackTitle,
                    artist: trackArtist,
                    album: trackAlbum,
                    duration: serverDuration,
                    bitrate: trackBitrate,
                    artworkURL: artworkURL,
                    playlistIndex: result["playlist_cur_index"] as? Int,
                    playlistTracks: result["playlist_tracks"] as? Int
                )

                DispatchQueue.main.async {
                    self.applyParsedMetadata(parsed, seq: seq)
                }

            } else {
                os_log(.error, log: logger, "[BOUNDARY-DRIFT] Failed to parse metadata response")
            }
        } catch {
            os_log(.error, log: logger, "[BOUNDARY-DRIFT] JSON parsing error: %{public}s", error.localizedDescription)
        }
    }

    /// Synchronous last-write-wins apply for a parsed metadata response. Gates the
    /// ENTIRE apply (playlist position → CarPlay buttons, bitrate → info line, and
    /// title/artist/album/artwork) on the seq so a stale response can't push ANY
    /// out-of-date field. Returns `true` if applied, `false` if dropped as stale.
    /// Accepts only responses NEWER than the last one applied, so a failed newer
    /// fetch can't sentence an in-flight good response to "stale until next track."
    /// Must be called on the main thread.
    @discardableResult
    func applyParsedMetadata(_ parsed: ParsedTrackMetadata, seq: Int) -> Bool {
        guard metadataGate.admit(seq) else {
            os_log(.info, log: logger, "[BOUNDARY-DRIFT] Dropping stale metadata (seq %d <= applied %d)", seq, metadataGate.lastAdmitted)
            return false
        }

        // Update CarPlay button states based on server's playlist position
        if let totalTracks = parsed.playlistTracks, let currentIndex = parsed.playlistIndex {
            os_log(.info, log: logger, "🎵 Playlist position: %d/%d", currentIndex + 1, totalTracks)
            audioManager.updatePlaylistPosition(currentIndex: currentIndex, totalTracks: totalTracks)
        }

        // Apply LMS's authoritative bitrate to the stream-info display.
        audioManager.updateStreamBitrate(text: parsed.bitrate)

        // Only update duration if server explicitly provides it (Material skin approach)
        if let duration = parsed.duration, duration > 0.0 {
            audioManager.updateTrackMetadata(
                title: parsed.title,
                artist: parsed.artist,
                album: parsed.album,
                artworkURL: parsed.artworkURL,
                duration: duration
            )
        } else {
            // Don't update duration - preserve existing duration
            audioManager.updateTrackMetadata(
                title: parsed.title,
                artist: parsed.artist,
                album: parsed.album,
                artworkURL: parsed.artworkURL
                // duration parameter omitted - keeps existing duration
            )
        }

        os_log(.info, log: logger, "[BOUNDARY-DRIFT] ✅ METADATA APPLIED TO LOCK SCREEN - new track info should appear now")
        return true
    }
    // MARK: - Helper Method to Determine Source Type
    // Add to SlimProtoConnectionManagerDelegate extension
    func connectionManagerShouldStorePosition() {
        os_log(.info, log: logger, "🔒 Connection lost - storing current position for recovery")
        
        // Save position to server for auto-resume functionality
        savePositionToServerPreferences()
    }

    func connectionManagerDidReconnectAfterTimeout() {
        os_log(.info, log: logger, "🔒 Reconnected after timeout - checking for position recovery")
        
        // Wait a moment for connection to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Server auto-resume handles position recovery
        }
    }




    // MARK: - Volume Control
    func setPlayerVolume(_ volume: Float) {
        // REMOVED: Noisy volume logs - os_log(.debug, log: logger, "🔊 Setting player volume: %.2f", volume)
        audioManager.setVolume(volume)
    }

    // MARK: - Synchronized Playback Control

    /// Start playback at a specific jiffies time (for multi-room audio synchronization)
    func startAtJiffies(_ targetJiffies: TimeInterval) {
        os_log(.info, log: logger, "🎯 Coordinator forwarding synchronized start to AudioManager")
        // STMs flush for sync-wait tracks now happens in
        // handleDecoderDidStartPlayback (fired by the decoder's sync-start timer
        // after BASS_ChannelPlay succeeds at the target jiffies).
        //
        // SyncController reset: jiffies-synchronized start re-anchors playback to the
        // server's clock. Any prior drift residual is meaningless across this point,
        // and the wait window for the target jiffies would otherwise be attributed
        // as phantom drift by tick()'s self-decay math.
        syncControllerReset(reason: "startAtJiffies")
        audioManager.startAtJiffies(targetJiffies)
    }

    /// Called by AudioManager when AudioStreamDecoder's BASS_ChannelPlay succeeds.
    /// Single source of truth for STMs timing on the push-stream path — matches
    /// squeezelite's `output.track_started` signal. Fires for autostart='1'
    /// (immediate, after startPlayback), autostart='0'/'2' jiffies=0 (after
    /// resumePlayback runs via didResumeStream), and autostart='0'/'2' jiffies>0
    /// (after sync-start timer fires BASS_ChannelPlay at the target time).
    func handleDecoderDidStartPlayback() {
        if pendingUnpauseSTMs {
            os_log(.info, log: logger, "🎵 Flushing deferred STMs (BASS playback started)")
            client.sendStatus("STMs")
            pendingUnpauseSTMs = false
        }
    }

    // MARK: - Sync Drift Corrections

    /// Play silence for a duration (timed pause for sync drift correction).
    /// Sub-100ms corrections route through SyncController's rate-match path
    /// (inaudible); larger corrections fall through to the existing pause/resume.
    func playSilence(duration: TimeInterval) {
        let ms = duration * 1000.0
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.settings.experimentalRateMatching {
                if self.syncController.ingestPlaySilence(durationMs: ms) {
                    return  // absorbed by rate-match path
                }
            }
            os_log(.info, log: self.logger, "⏸️🔇 Coordinator forwarding play silence (%.1fms) to AudioManager", ms)
            self.audioManager.playSilence(duration: duration)
        }
    }

    /// Skip ahead by consuming buffer (sync drift correction).
    /// Sub-100ms corrections route through SyncController's rate-match path;
    /// larger corrections fall through to the existing byte-discard mechanism.
    func skipAhead(duration: TimeInterval) {
        let ms = duration * 1000.0
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.settings.experimentalRateMatching {
                if self.syncController.ingestSkipAhead(durationMs: ms) {
                    return  // absorbed by rate-match path
                }
            }
            os_log(.info, log: self.logger, "⏩ Coordinator forwarding skip ahead (%.1fms) to AudioManager", ms)
            self.audioManager.skipAhead(duration: duration)
        }
    }

    // MARK: - SyncController wiring

    private func setupSyncController() {
        syncController.positionBytesProvider = { [weak self] in
            self?.audioManager.pushStreamPositionBytes() ?? 0
        }
        syncController.nominalBytesPerSecondProvider = { [weak self] in
            self?.audioManager.nominalBytesPerSecond ?? 352800
        }
    }

    /// Called from the 1Hz playbackHeartbeatTimer block.
    fileprivate func tickSyncController() {
        guard settings.experimentalRateMatching else { return }
        syncController.tick()
    }

    /// Public reset hook for SyncController — called from lifecycle sites.
    func syncControllerReset(reason: String) {
        DispatchQueue.main.async { [weak self] in
            self?.syncController.reset(reason: reason)
        }
    }

    /// Debug snapshot for Phase 2 verification harness.
    var debugSyncController: SyncController { syncController }

}

// MARK: - JSON-RPC runner seam (98q.13)

/// Single-method seam over the stateless JSON-RPC direct-command path.
/// Views and models that only fire a query and parse the response depend on
/// this instead of the full coordinator, so unit tests can inject a mock
/// runner (delayed / out-of-order completions) — see SearchResultsModelTests.
protocol SlimProtoJSONRPCRunner: AnyObject {
    func sendJSONRPCCommandDirect(_ jsonRPC: [String: Any], completion: @escaping ([String: Any]) -> Void)
}

extension SlimProtoCoordinator: SlimProtoJSONRPCRunner {}

// MARK: - Playlist mode cycles (w53)

/// LMS playlist-mode toggle orderings, pure so unit tests can pin them:
/// - shuffle: 0 off → 1 songs → 2 albums → 0 (pre-existing toggleShuffleMode order)
/// - repeat:  0 off → 2 all → 1 one → 0 (Apple Music ordering)
enum PlaylistModeCycle {
    static func nextShuffle(_ current: Int) -> Int {
        switch current {
        case 1: return 2   // songs → albums
        case 2: return 0   // albums → off
        default: return 1  // off (or unknown) → songs
        }
    }

    static func nextRepeat(_ current: Int) -> Int {
        switch current {
        case 2: return 1   // all → one
        case 1: return 0   // one → off
        default: return 2  // off (or unknown) → all
        }
    }
}
