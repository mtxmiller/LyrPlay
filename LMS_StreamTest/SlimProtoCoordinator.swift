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

    // MARK: - Unified Recovery System (LMS_StreamTest-6lb)
    /// What triggered the current/pending reconnection - determines recovery behavior
    var pendingRecoveryTrigger: RecoveryTrigger = .none
    /// Was audio playing when connection was lost? (for networkRestored recovery)
    private var wasPlayingBeforeDisconnect: Bool = false
    /// Was audio paused when connection was lost? (for networkRestored recovery)
    private var wasPausedBeforeDisconnect: Bool = false
    /// Outage hold (bd 6lvg, 8tjj): on while we're trying to get back to
    /// playback the user asked for (connection lost while playing, remote play,
    /// audible recovery). Keeps the output device running so iOS doesn't
    /// suspend the app, keeps reconnecting, and counts as "was playing" across
    /// repeated disconnects. Ends when new playback actually starts, on a
    /// pause, or after `outageHoldLimit`.
    private var outageHoldActive = false
    private var outageHoldGeneration = 0
    private static let outageHoldLimit: TimeInterval = 600
    /// Audible recovery retries after a failed jump / no playback (bd 6lvg).
    private var audibleRecoveryRetries = 0
    private static let maxAudibleRecoveryRetries = 3

    struct RecoveryTarget: Equatable {
        let index: Int
        let position: Double
    }
    /// Where this outage hold's audible recovery jumped to (bd fykj). The saved
    /// recovery data can't be trusted for retries: it's deleted once LMS accepts
    /// the jump, and if LMS then can't stream to us it skips through the queue
    /// and the 3s poll copies that new index in. Retries reuse this target
    /// until the hold ends (playback started, paused, gave up).
    private var audibleRecoveryTarget: RecoveryTarget?

    /// Which target a recovery jumps to. A retry within the same outage hold
    /// keeps the original target: nothing has played since, so the user is
    /// still where it was.
    static func resolveRecoveryTarget(saved: RecoveryTarget?, kept: RecoveryTarget?, isAudibleRetry: Bool) -> RecoveryTarget? {
        if isAudibleRetry, let kept = kept { return kept }
        return saved
    }

    /// Media services reset (bd 27ye): what playback looked like at the loss
    /// and at the reset. iOS can post the reset without a loss first.
    struct MediaServicesSnapshot: Equatable {
        var audioPlaying = false              // playing, or stalled waiting for data
        var outageHoldActive = false
        var audibleRecoveryInProgress = false
        var silentRecoveryInProgress = false  // app-open recovery: mute, jump, pause
        var startDroppedWhileSuspended = false

        var wantsPlayback: Bool {
            // During a silent (app-open) recovery the muted stream "plays" and
            // its start may be dropped; neither is a request to play (rule 12).
            outageHoldActive || audibleRecoveryInProgress
                || ((audioPlaying || startDroppedWhileSuspended) && !silentRecoveryInProgress)
        }
    }

    enum MediaServicesResetAction: Equatable {
        case reinitialize           // paused or idle: re-init BASS, start no audio
        case reinitializeAndResume  // then resume via playlist-jump recovery
    }

    static func mediaServicesResetAction(atLoss: MediaServicesSnapshot?, atReset: MediaServicesSnapshot) -> MediaServicesResetAction {
        let wanted = (atLoss?.wantsPlayback ?? false) || atReset.wantsPlayback
        return wanted ? .reinitializeAndResume : .reinitialize
    }

    /// playlist_cur_index from an LMS status result (LMS sends it as a string).
    static func playlistIndex(fromStatus result: [String: Any]?) -> Int? {
        if let index = result?["playlist_cur_index"] as? Int { return index }
        if let text = result?["playlist_cur_index"] as? String { return Int(text) }
        return nil
    }

    /// The saved recovery target, or nil when there's nothing complete to
    /// jump to. A missing index must not become 0: saves that write only
    /// position + timestamp (disconnect, pause, media services reset) can run
    /// right after a jump deleted all three keys (bd 27ye).
    static func savedRecoveryTarget(hasTimestamp: Bool, index: Int?, position: Double) -> RecoveryTarget? {
        guard hasTimestamp, let index = index else { return nil }
        return RecoveryTarget(index: index, position: position)
    }

    /// A second reset notification right after one we already handled, with
    /// no loss in between, is the same event: re-initializing again would free
    /// the stream we just started and jump twice. A re-init done by the
    /// no-reset fallback doesn't count — it ran before the services were back,
    /// so the real reset still needs its own re-init.
    static func isDuplicateReset(secondsSinceResetReinit: TimeInterval?, lostSinceReinit: Bool) -> Bool {
        guard let seconds = secondsSinceResetReinit, !lostSinceReinit else { return false }
        return seconds < 5
    }

    private var mediaServicesLossSnapshot: MediaServicesSnapshot?
    /// Playback position when the loss arrived. Once the stream is freed our
    /// STATs report 0 elapsed, LMS's time follows, and the 3s server poll
    /// copies that into the tracker before the reset — so read it here.
    private var mediaServicesLossPosition: Double?
    private var mediaServicesGeneration = 0
    private var mediaServicesReinitInFlight = false
    private var lastResetReinitAt: Date?
    private var mediaServicesLostSinceReinit = false
    /// When the SlimProto connection last came up, and when the server last
    /// sent strm 's'. On reconnect LMS restarts a playing client by itself
    /// (Squeezebox.pm reconnect → _Continue → _JumpToTime); a jump of ours on
    /// top of that collides (LMS serves one stream per player) and can leave
    /// the new stream waiting forever (bd 6lvg, captured in the outage rig).
    private var lastConnectedAt: Date?
    private var lastServerStreamStartAt: Date?
    /// The server ("host:port") of the last connection in this process: a
    /// reconnect HELO is only for the server that has our session.
    private var sessionServer: String?
    /// The streaming track's decode ended while we couldn't reach the server.
    /// A cut download ends exactly like a finished one, so its STMd (and the
    /// STMu when the buffer drains) wait until a reconnect HELO, when LMS can
    /// tell us the track's duration. Main thread only.
    private var decodeEndHeld = false
    private var drainHeld = false
    private var resolvingHeldTrackEnd = false
    /// Where the audio was (track, time) when a reconnect HELO went out under
    /// an outage hold. After LMS's 300s forget time it ignores the bit and
    /// restarts at its own saved position; this is where to put it instead.
    private var reconnectTarget: RecoveryTarget?
    /// reconnectTarget is where downloaded copies took us: any track, not just LMS's.
    private var reconnectTargetFromLifeboat = false
    /// LMS's forgotten-player restart was muted (it would play the wrong place).
    private var lifeboatRestartMuted = false
    /// Downloaded copies of the queue (ride out network loss, phase 2).
    private let lifeboat = LifeboatCache()
    /// Playing a downloaded copy now (no stream from LMS).
    private var lifeboatActive = false
    /// A downloaded copy of a LATER track played since LMS last streamed to
    /// us: LMS doesn't know where we are, so the reconnect jumps it there.
    /// (Continuing the cut track from its copy doesn't: LMS still has that
    /// track, and our STATs keep its time.)
    private var lifeboatUsed = false
    private var lifeboatWatchTimer: Timer?
    private var lifeboatPlanAt: Date?
    /// When the current decode end was held (a server restart after it supersedes it).
    private var decodeEndHeldAt: Date?
    /// Copies that couldn't be switched to (format, no match): never retried.
    private var unusableCopies: Set<String> = []
    /// Connection the lifeboat jump was sent on (one per connection).
    private var lifeboatJumpConnection: Date?
    /// LMS's ReplayGain for the last stream (0 = LMS applies none for us).
    private var lastStreamReplayGain: Float = 0
    private var lifeboatCacheCleared = false
    /// Paused with the lock screen / CarPlay while offline (LMS doesn't know).
    private var lifeboatPausedLocally = false
    /// The next silent recovery restores paused even if LMS says it's playing
    /// (it only "plays" because it never got our offline pause).
    private var forcePausedRestore = false
    /// "Play Saved Music" was pressed with no server: LMS's pause (or stop)
    /// is older than that press, so the reconnect plays over it.
    private var savedMusicStartedOffline = false
    /// Saved music was started from a button: the UI opens the offline player.
    var offlinePlayerRequested = false
    /// Set by a lost connection or failed connect, cleared on connect: the
    /// first second of a normal launch (not yet connected) isn't "offline".
    private var serverUnreachableSince: Date?
    /// Format of the last stream LMS sent (picks the copies' format).
    private var currentStreamFormat = ""
    /// Last time any SlimProto frame arrived from the server.
    private var lastServerMessageAt: Date?

    /// True when the server has sent us something on the current connection
    /// within the last 15s. A socket can "connect" on a half-dead path (or to a
    /// local tunnel) without the server seeing us, or go half-dead later; a
    /// recovery jump sent then makes LMS fail to stream to us and skip through
    /// the whole queue in under a second ("only 0 of 1 players started
    /// streaming", captured in the outage rig, bd 6lvg). LMS polls every player
    /// with strm 't' every 5s (Slimproto.pm check_all_clients), so a healthy
    /// connection is never quiet for 15s.
    private var serverHeardRecently: Bool {
        guard let connected = lastConnectedAt, let heard = lastServerMessageAt else { return false }
        return heard >= connected && Date().timeIntervalSince(heard) < 15
    }

    /// The connection is still usable: the server sent something on it within
    /// `liveConnectionWindow`. LMS closes a player it hasn't heard from for 15s
    /// (3 polls of 5s, Slimproto.pm check_all_clients), and a paused iOS app is
    /// suspended within seconds and can't answer, so after ~15-20s away the
    /// server has already dropped us. This replaces the old guess (background
    /// > 45s). A live connection alone doesn't mean LMS still has our paused
    /// stream (a new connection after a relaunch doesn't), so resuming in place
    /// also needs resumeRoute's other checks.
    var connectionIsLive: Bool {
        guard connectionManager.connectionState.isConnected,
              let heard = secondsSinceServerHeardOnThisConnection else { return false }
        return heard < Self.liveConnectionWindow
    }

    /// Under LMS's 15s close, with room for its 5s check interval.
    static let liveConnectionWindow: TimeInterval = 10

    enum ResumeRoute: Equatable {
        case leaveAlone      // LMS is playing us: nothing to restore
        case resumeInPlace   // LMS holds our paused stream: plain unpause / nothing to restore
        case recover         // reconnect if needed, then playlist jump
    }

    /// Ask LMS, don't guess. On a live connection: LMS playing → leave it alone
    /// (a stall or track gap looks "not paused" locally); LMS paused and we hold
    /// the paused stream → resume in place. Anything else (a relaunch, LMS
    /// stopped the player when it dropped us, a failed or empty status reply)
    /// recovers. "Unknown" covers BASS's device-paused state after an interruption.
    static func resumeRoute(connectionLive: Bool, localState: String,
                            serverMode: String?, serverConnected: Bool?) -> ResumeRoute {
        guard connectionLive, serverConnected == true else { return .recover }
        if serverMode == "play" { return .leaveAlone }
        if serverMode == "pause" && (localState == "Paused" || localState == "Unknown") { return .resumeInPlace }
        return .recover
    }

    /// `player_connected` from a status result (LMS sends 0/1, sometimes as a string).
    static func statusPlayerConnected(_ result: [String: Any]?) -> Bool? {
        if let value = result?["player_connected"] as? Int { return value == 1 }
        if let text = result?["player_connected"] as? String { return text == "1" }
        return nil
    }

    private var secondsSinceServerHeardOnThisConnection: TimeInterval? {
        guard let connected = lastConnectedAt, let heard = lastServerMessageAt, heard >= connected else { return nil }
        return Date().timeIntervalSince(heard)
    }

    /// Decide how to resume. With a live connection ask LMS (one status call,
    /// ~50ms on the LAN); without one there's nothing to ask: recover.
    /// Completion runs on main.
    func decideResumeRoute(_ completion: @escaping (ResumeRoute) -> Void) {
        guard connectionIsLive else {
            os_log(.info, log: logger, "🧭 Resume route: recover (connection not live)")
            completion(.recover)
            return
        }
        let statusCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["status", "-", 1]]
        ]
        sendJSONRPCCommandDirect(statusCommand, timeout: 2.0) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let result = response["result"] as? [String: Any]
                let mode = result?["mode"] as? String
                let connected = Self.statusPlayerConnected(result)
                // Re-check: the socket may have died while we asked.
                let localState = self.audioManager.getPlayerState()
                let route = Self.resumeRoute(connectionLive: self.connectionIsLive, localState: localState,
                                             serverMode: mode, serverConnected: connected)
                os_log(.info, log: self.logger, "🧭 Resume route: %{public}s (server mode %{public}s, connected %{public}s, local %{public}s)",
                       String(describing: route), mode ?? "none",
                       connected.map { $0 ? "yes" : "no" } ?? "unknown", localState)
                completion(route)
            }
        }
    }

    /// The remote play waiting on decideResumeRoute; a pause/stop clears it.
    private var remotePlayIntent: UUID?
    /// A remote play is being decided: app-open recovery must not start under it.
    var remotePlayPending: Bool { remotePlayIntent != nil }

    /// Set when a remote play was sent as a plain unpause; checked 3s later.
    private var resumeInPlaceCheck: UUID?

    /// True if the server has started a stream since we last (re)connected.
    private var serverStartedStreamSinceConnect: Bool {
        guard let connected = lastConnectedAt, let started = lastServerStreamStartAt else { return false }
        return started >= connected
    }
    /// Ignore server-time polls until this instant. Set when a playlist-jump
    /// recovery is issued: the server computes displayed time as
    /// startOffset + the client's last STAT elapsed, and STATs sent during the
    /// reconnect window still carry the DEAD pre-background stream's position —
    /// so for up to ~1s after the jump the server reports startOffset + stale
    /// elapsed (observed: exactly 2× the resume position, bd LMS_StreamTest-egd
    /// follow-up). A 3s poll that samples that window paints and interpolates
    /// the spike on the lock screen ("timer hunts"). We know the true position
    /// (we chose it), so we seed the tracker and skip polls while poisoned.
    private var suppressServerTimePollsUntil: Date?
    /// A remote play that reconnects and recovers holds the saved position on
    /// screen from the press to the jump. Meanwhile LMS stops the player on
    /// reconnect (strm 'q' zeroes the time) and reports the previous jump's
    /// start offset (device log 2026-10-17: 234 → 0 → 227 → 234). The jump's
    /// own window takes over; ends with the outage hold.
    private var holdTimeUntilRecoveryJump = false

    // MARK: - Player Synchronization (Multi-room Audio)
    private var jiffiesEpoch: TimeInterval = 0  // Offset between server time and local jiffies
    private var jiffiesOffsetList: [TimeInterval] = []  // Track drift for corrections (max 8 entries)
    private var syncGroupID: String?  // 10-digit sync group ID from serv packet (PHASE 5)
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


    // MARK: - Public Interface
    func connect() {
        os_log(.info, log: logger, "Starting connection to %{public}s server...", settings.currentActiveServer.displayName)
        
        lastKnownHost = settings.activeServerHost
        lastKnownPort = UInt16(settings.activeServerSlimProtoPort)
        
        connectionManager.willConnect()
        client.updateServerSettings(host: settings.activeServerHost, port: UInt16(settings.activeServerSlimProtoPort))
        connectKeepingFreshSocket()
    }

    /// client.connect(), but when it keeps a socket that's already up, tell the
    /// connection manager: it just set .connecting/.reconnecting and no didConnect
    /// will come to undo that (health checks skip anything not .connected).
    private func connectKeepingFreshSocket() {
        if client.connect() == .keptConnected {
            connectionManager.didConnect()
            // No slimProtoDidConnect will come to run a recovery queued for this connect.
            // Not .networkRestored: the kept socket's own didConnect already ran that.
            if pendingRecoveryTrigger == .appOpen || pendingRecoveryTrigger == .lockScreen {
                handlePendingRecovery()
            }
        }
    }
    
    func disconnect() {
        os_log(.info, log: logger, "🔌 Disconnecting from server with position save")
        DispatchQueue.main.async { [weak self] in
            self?.endOutageHold(reason: "user disconnect")
        }
        connectionManager.userInitiatedDisconnection()
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

    /// Request server-side seek for transcoding pipeline fixes
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.lifeboatHoldsSession else { return }
            self.endOutageHold(reason: "playback started")
        }

        // This is when we should send STMs (track started playing)
        // Only after RESP and STMc have been sent
        client.sendStatus("STMs")
    }
    
    deinit {
        stopServerTimeFetching()  // Stop our simplified server time fetching
        // Use position-saving disconnect when app is being deallocated
        client.disconnectWithPositionSave()
    }
    
    // MARK: - Recovery State Management
    // All recovery state below is main-thread-confined: check-and-set, clears,
    // and every timeout/completion closure that touches it hops to main first.
    private var isRecoveryInProgress = false
    /// Whether the lock-holding recovery is a silent (shouldPlay=false) one.
    /// A silent recovery rejected by the lock must NOT unmute when the holder
    /// is itself silent — the holder's dance owns the unmute (bd 34l).
    private var currentRecoveryIsSilent = false
    /// Read-only view for ContentView's app-open pre-mute (bd 34l): don't VOL-mute
    /// audio that an in-flight recovery (e.g. lock-screen resume) already owns.
    var isRecoveryActive: Bool { isRecoveryInProgress }
    /// Monotonic token identifying the current recovery. The 10s stuck-lock timeout
    /// and the playlist-jump completion capture their generation and no-op if a
    /// newer recovery has since started — a stale timer must not clear a later
    /// recovery's lock or unmute its mid-establishment silent stream (audio burst).
    private var recoveryGeneration = 0
    // Armed during silent (app-open) recovery once the pause command is sent. The unmute
    // is gated on the real STMp pause confirmation in didPauseStream() rather than a fixed
    // timer, so DSP gain is only restored after audio has actually stopped flowing.
    private var awaitingSilentRecoveryUnmute = false
    /// The silent recovery whose pause hasn't been sent yet. The pause goes out
    /// when its muted stream starts playing, or from the fallback timer.
    private var silentRecoveryPauseGeneration: Int?
    /// Set by a user play: a silent recovery must not keep re-sending its pause.
    private var silentPauseResendCancelled = false
    /// A silent recovery is waiting for the server to talk on the connection.
    private var silentRecoveryWaiting = false

    /// A silent recovery owns the mute: waiting, mid jump, or waiting to pause or unmute.
    private var silentRecoveryOwnsMute: Bool {
        silentRecoveryWaiting
            || (isRecoveryInProgress && currentRecoveryIsSilent)
            || silentRecoveryPauseGeneration != nil
            || awaitingSilentRecoveryUnmute
    }
    
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
            self.setRecoveryIndexFromServer(playlistCurIndex)
            UserDefaults.standard.set(currentPosition, forKey: "lyrplay_recovery_position")
            UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
            
            os_log(.info, log: self.logger, "💾 Saved recovery state: track %d at %.2f seconds (live position)", playlistCurIndex, currentPosition)
        }
    }
    
    // MARK: - Recovery Index (single write path, bd LMS_StreamTest-433.5.4)

    /// lyrplay_recovery_index previously had four racing writers (local
    /// boundary increment, 3s server-time poll, position-save roundtrip, and
    /// two no-op self-assignments). A poll response that left the server
    /// BEFORE a gapless boundary could land AFTER the local increment and
    /// rewind the index — the next recovery then jumped to the PREVIOUS track.
    /// All writes now route through the two methods below. UserDefaults-backed
    /// (thread-safe) because the position-save write arrives on a URLSession
    /// completion thread.
    private static let recoveryIndexBumpStampKey = "lyrplay_recovery_index_bumped_at"

    /// Reject a server-derived index that moves BACKWARD within a short window
    /// after a local boundary bump — it's a stale in-flight response. Backward
    /// moves outside the window are legitimate (user picked an earlier track).
    static func acceptServerRecoveryIndex(current: Int, proposed: Int, secondsSinceBoundaryBump: TimeInterval) -> Bool {
        if proposed >= current { return true }
        return secondsSinceBoundaryBump > 10.0
    }

    /// Local increment at a gapless track boundary — always wins, stamps its time.
    func bumpRecoveryIndexAtBoundary() {
        // Missing index: bumping would invent track 1, a valid jump target.
        // Leave it missing; the 3s poll or recovery's status query fills it in (bd 27ye).
        guard let bumped = Self.indexAfterBoundary(UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int) else {
            os_log(.info, log: logger, "📍 Track boundary: no recovery index saved - not bumping")
            return
        }
        UserDefaults.standard.set(bumped, forKey: "lyrplay_recovery_index")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.recoveryIndexBumpStampKey)
        os_log(.info, log: logger, "📍 Track boundary: recovery index incremented to %d", bumped)
    }

    /// Index after a gapless boundary, or nil when none is saved.
    static func indexAfterBoundary(_ saved: Int?) -> Int? {
        saved.map { $0 + 1 }
    }

    /// Server-derived index (status poll / position-save roundtrip), stale-guarded.
    func setRecoveryIndexFromServer(_ index: Int) {
        // Playing downloaded copies: LMS's index is where it was left, not where
        // we are (device log 2026-10-19: a save on a reconnect timeout put back
        // track A after an offline skip to B, and the jump went to A).
        guard !lifeboatUsed else {
            os_log(.info, log: logger, "📍 Ignoring server recovery index %d - playing downloaded copies", index)
            return
        }
        let current = UserDefaults.standard.integer(forKey: "lyrplay_recovery_index")
        let bumpedAt = UserDefaults.standard.double(forKey: Self.recoveryIndexBumpStampKey)
        let sinceBump = Date().timeIntervalSince1970 - bumpedAt
        if Self.acceptServerRecoveryIndex(current: current, proposed: index, secondsSinceBoundaryBump: sinceBump) {
            UserDefaults.standard.set(index, forKey: "lyrplay_recovery_index")
        } else {
            os_log(.info, log: logger, "📍 Rejected stale server recovery index %d (current %d, %.1fs after boundary bump)", index, current, sinceBump)
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
            self.refreshMaterialStatus()
            os_log(.info, log: self.logger, "🔊 Silent recovery complete - volume restored (%{public}s)", reason)
        }
    }

    /// Fallback for streams that don't report playback start: pause once the
    /// player says Playing. A pause sent before the stream starts is a no-op on
    /// the server (Pause while buffering), so don't send it early. Checks every
    /// 0.5s, then settles.
    private func pauseSilentRecoveryWhenPlaying(generation: Int, checksLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.silentRecoveryPauseGeneration == generation else { return }
            // A push stream's STMs goes out in handleDecoderDidStartPlayback, which also
            // pauses; until then the server is still buffering and ignores a pause.
            if self.audioManager.getPlayerState() == "Playing" && !self.pendingUnpauseSTMs {
                self.sendSilentRecoveryPause(generation: generation, reason: "player state playing")
            } else if checksLeft > 1 {
                self.pauseSilentRecoveryWhenPlaying(generation: generation, checksLeft: checksLeft - 1)
            } else {
                // The stream never played: end the recovery (pauses locally and on
                // the server if anything is flowing, then unmutes, clears the arm).
                self.settleSilentRecoveryAudio(reason: "silent stream never played")
            }
        }
    }

    /// The pause goes over HTTP while STMs goes over SlimProto, and LMS ignores a
    /// pause that arrives before STMs (Pause while buffering is a no-op,
    /// StreamingController.pm). Simulator 2026-10-16: lost that race once and the
    /// fallback paused 4s late. Re-send until the STMp confirmation lands
    /// (["pause","1"] is idempotent).
    /// Stops early if another recovery took over or the user asked to play.
    private func resendSilentRecoveryPauseIfUnconfirmed(generation: Int, attemptsLeft: Int) {
        // Every 0.25s: each wait is played (muted) past the saved position.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, self.awaitingSilentRecoveryUnmute, attemptsLeft > 0,
                  self.recoveryGeneration == generation, !self.silentPauseResendCancelled else { return }
            os_log(.info, log: self.logger, "⏸️ Silent recovery: pause not confirmed - sending again")
            self.sendNormalJSONRPCCommand("pause")
            self.resendSilentRecoveryPauseIfUnconfirmed(generation: generation, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Pause a silent recovery's muted stream, once. Must be called on main.
    private func sendSilentRecoveryPause(generation: Int, reason: String) {
        // If a newer recovery started, it owns the stream now: pausing it or
        // arming our unmute latch would corrupt it.
        guard silentRecoveryPauseGeneration == generation else { return }
        // A user play is being decided: it takes this recovery over when it lands.
        guard remotePlayIntent == nil else { return }
        silentRecoveryPauseGeneration = nil
        guard recoveryGeneration == generation else { return }
        os_log(.info, log: logger, "⏸️ Silent recovery: pausing (%{public}s)", reason)

        // Arm the event-gated unmute BEFORE sending pause. didPauseStream() will
        // restore volume the moment the STMp pause confirmation lands — i.e. once
        // BASS is actually paused. The old fixed +2s timer could fire while the
        // stream was still playing (or before the async STRM start landed), which
        // is what leaked the intermittent (~10%) blip.
        awaitingSilentRecoveryUnmute = true

        // Straight to the server: sendJSONRPCCommand("pause") waits 0.5s first,
        // and every 1/10s here is played (muted) past the saved position.
        sendNormalJSONRPCCommand("pause")
        resendSilentRecoveryPauseIfUnconfirmed(generation: generation, attemptsLeft: 6)

        // Fallback ceiling: if the pause confirmation never arrives, unmute anyway
        // so the engine is never left muted. No-op if didPauseStream already did it.
        // Deliberately NOT generation-gated: its only job is "never stay muted",
        // which is safe to enforce in any generation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self = self, self.awaitingSilentRecoveryUnmute else { return }
            self.awaitingSilentRecoveryUnmute = false
            self.settleSilentRecoveryAudio(reason: "fallback timer")
        }
    }

    /// Nudge Material to poll player status NOW instead of waiting for its own
    /// (background-dazed) Cometd cycle. During app-open recovery the server is
    /// genuinely playing for ~2s before our pause lands; without this nudge
    /// Material can show "playing" for several more seconds after the pause.
    /// Same bus event Material fires internally after its own commands.
    private func refreshMaterialStatus() {
        #if os(iOS)
        guard let webView = webView else { return }
        DispatchQueue.main.async {
            webView.evaluateJavaScript(
                "if (typeof bus !== 'undefined' && bus.$emit) { bus.$emit('refreshStatus'); }",
                completionHandler: nil
            )
        }
        #endif
    }

    /// Timeout-path teardown for silent recovery (bd 34l): the STMp pause
    /// confirmation may never arrive, so unlike finishSilentRecoveryIfArmed
    /// (which runs AFTER a real pause), audio may still be flowing here.
    /// If the engine is muted and not settled ("Buffering"/stalled counts —
    /// BASS auto-resumes a stalled stream when data arrives, so it is NOT
    /// safe to unmute), pause locally, mark the tracker paused, and retry the
    /// server pause before restoring gain. Paused-at-position is silent
    /// recovery's intended end state; the re-sent pause re-aligns the server
    /// whenever it lands (didPauseStream then runs the full bookkeeping).
    /// Must be called on main.
    private func settleSilentRecoveryAudio(reason: String) {
        // This recovery is over: its pause must not fire on a later stream (the user's own play).
        silentRecoveryPauseGeneration = nil
        silentRecoveryWaiting = false
        if audioManager.isSilentRecoveryMuted {
            let state = audioManager.getPlayerState()
            if state != "Paused" && state != "Stopped" {
                os_log(.info, log: logger, "⏸️ %{public}s: state '%{public}s' may still be audible - pausing locally + retrying server pause", reason, state)
                audioManager.pause()
                simpleTimeTracker.updateFromServer(time: simpleTimeTracker.getCurrentTimeDouble(), playing: false)
                sendJSONRPCCommand("pause")
                // The retried pause lands asynchronously — poll Material again
                // after it should have settled so the UI doesn't sit on "playing".
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.refreshMaterialStatus()
                }
            }
        }
        audioManager.disableSilentRecoveryMode()
        refreshMaterialStatus()
        os_log(.info, log: logger, "🔊 Silent recovery complete - volume restored (%{public}s)", reason)
    }

    /// Early-return path when recovery has no data to jump with. THE BLIP (bd 34l,
    /// captured in device log 2026-07-12): a double-triggered app open (.networkRestored
    /// from the background reconnect timer + .appOpen from ContentView) runs two silent
    /// recoveries; the first consumes the recovery data and starts its muted jump→pause
    /// dance, the second lands here, and the old bare disableSilentRecoveryMode()
    /// unmuted the first one's STILL-PLAYING muted stream ~1s before any pause landed.
    /// For !shouldPlay, settle instead: pause BEFORE unmuting. pause is sent as
    /// explicit ["pause","1"], so the extra send is idempotent.
    private func finishRecoveryWithoutJump(shouldPlay: Bool) {
        if shouldPlay {
            audioManager.disableSilentRecoveryMode()
            sendJSONRPCCommand("play")
        } else {
            settleSilentRecoveryAudio(reason: "no recovery data")
            sendJSONRPCCommand("pause")
        }
        isRecoveryInProgress = false
    }

    /// Recovery waits for the server to talk on the new connection: checks every
    /// `serverWaitInterval`, up to `serverWaitAttempts` times (10s).
    static let serverWaitInterval: TimeInterval = 0.25
    static let serverWaitAttempts = 40

    func performPlaylistRecovery(shouldPlay: Bool = true, serverWaitAttempt: Int = 0) {
        // Check-and-set must happen on the same queue that clears the lock (main).
        // The old recoveryQueue hop didn't serialize against main-thread clears, so
        // two near-simultaneous triggers could both pass the guard and interleave
        // (double playlist jump / double mute-unmute). bd LMS_StreamTest-433.3.2
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Audible recovery = the user wants audio: stay awake until it
            // actually starts (bd 6lvg, 8tjj).
            if shouldPlay {
                self.beginOutageHold(reason: "audible recovery")
            }

            // One silent recovery at a time, from its request to its unmute. A
            // second one (a reconnect's .networkRestored during an app-open wait)
            // would find the data used up and settle the first one's still-playing
            // muted stream: the bd 34l blip. The first one owns the mute.
            if !shouldPlay && serverWaitAttempt == 0 && self.silentRecoveryOwnsMute {
                os_log(.info, log: self.logger, "🔇 Silent recovery already under way - skipping this one")
                return
            }

            // A user play is under way (being decided, recovering under the
            // outage hold, or resumed in place): landing paused would undo it.
            // A reconnect's .networkRestored waits 0.5s, so a lock-screen play
            // can land in between (device log 2026-10-17: the silent jump ran
            // first and Play had to be pressed twice).
            if !shouldPlay && serverWaitAttempt == 0
                && (self.outageHoldActive || self.remotePlayPending || self.resumeInPlaceCheck != nil) {
                os_log(.info, log: self.logger, "🔇 Silent recovery: a play is under way - skipping")
                self.liftPreMuteForAudibleRecovery()
                return
            }

            // Only jump while the server is actually talking to us on this
            // connection — otherwise LMS can't stream to us and runs through the
            // whole queue (see serverHeardRecently).
            if !self.serverHeardRecently {
                // LMS answers HELO within milliseconds, so check often; same 10s cap as before.
                if serverWaitAttempt < Self.serverWaitAttempts {
                    if serverWaitAttempt == 0 {
                        os_log(.info, log: self.logger, "[APP-RECOVERY] ⏳ Server not heard on this connection yet - waiting (up to %.0fs)",
                               Double(Self.serverWaitAttempts) * Self.serverWaitInterval)
                    }
                    let connectionStamp = self.lastConnectedAt
                    let generationAtWait = self.recoveryGeneration
                    if !shouldPlay {
                        self.silentRecoveryWaiting = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.serverWaitInterval) { [weak self] in
                        guard let self = self else { return }
                        // Silent, but another recovery ran meanwhile (an audible one: it
                        // lifted the mute and owns playback now). Restoring paused would
                        // undo it.
                        if !shouldPlay && self.recoveryGeneration != generationAtWait {
                            os_log(.info, log: self.logger, "[APP-RECOVERY] ⏳ Dropping silent wait (another recovery ran)")
                            self.silentRecoveryWaiting = false
                            return
                        }
                        // Audible: the hold watchdog retries on a new connection, and
                        // once audio has started (hold ended) there is nothing left to do.
                        // Silent: nothing else will run it (its trigger was consumed) and
                        // the engine is already muted, so keep waiting on the new
                        // connection (simulator log 2026-10-16: dropped here, recovery
                        // never ran, muted until the 20s ceiling).
                        guard !shouldPlay || (self.lastConnectedAt == connectionStamp && self.outageHoldActive) else {
                            os_log(.info, log: self.logger, "[APP-RECOVERY] ⏳ Dropping stale wait (connection changed or playback started)")
                            return
                        }
                        self.performPlaylistRecovery(shouldPlay: shouldPlay, serverWaitAttempt: serverWaitAttempt + 1)
                    }
                    return
                }
                os_log(.error, log: self.logger, "[APP-RECOVERY] ⏳ Server still not heard - not sending recovery on this connection")
                if shouldPlay {
                    // Retried by the next reconnect (health check drops this one).
                    self.pendingRecoveryTrigger = .networkRestored
                } else {
                    self.settleSilentRecoveryAudio(reason: "server not heard")
                }
                return
            }
            if !shouldPlay {
                self.silentRecoveryWaiting = false
            }

            // LMS restarts a known playing client by itself on reconnect, and
            // the wait above can outlast the first check in handlePendingRecovery.
            // A jump on top of a stream the server just started collides (one
            // stream per player); the hold watchdog retries if it fails.
            if shouldPlay && self.serverStartedStreamRecently {
                os_log(.info, log: self.logger, "[APP-RECOVERY] 🔄 Server started a stream recently - skipping jump")
                self.liftPreMuteForAudibleRecovery()
                return
            }

            // Check if recovery is already in progress
            guard !self.isRecoveryInProgress else {
                os_log(.info, log: self.logger, "🔒 Playlist Recovery: Skipping - recovery already in progress")
                // A rejected SILENT recovery already muted the engine
                // (enableSilentRecoveryMode at the .appOpen trigger), and none of
                // its settle paths will ever run. If the lock holder is AUDIBLE it
                // will never unmute either, so do it now. If the holder is itself
                // a silent recovery (double app-open trigger: .networkRestored +
                // .appOpen — the captured bd 34l blip), leave the mute alone: the
                // holder's own jump→pause dance settles it, and unmuting here
                // would blast its still-playing muted stream.
                if !shouldPlay && self.audioManager.isSilentRecoveryMuted && !self.currentRecoveryIsSilent {
                    os_log(.info, log: self.logger, "🔊 Silent recovery rejected by lock - unmuting (owner is audible)")
                    self.audioManager.disableSilentRecoveryMode()
                }
                return
            }

            // Set recovery in progress
            self.isRecoveryInProgress = true
            self.currentRecoveryIsSilent = !shouldPlay
            if !shouldPlay {
                // A user play from here on stops this recovery's pause re-sends.
                self.silentPauseResendCancelled = false
            }
            self.recoveryGeneration += 1
            os_log(.error, log: self.logger, "[APP-RECOVERY] 🔒 PLAYLIST RECOVERY STARTED (shouldPlay: %{public}s, gen %d)", shouldPlay ? "YES" : "NO", self.recoveryGeneration)

            guard !shouldPlay else {
                self.executePlaylistRecovery(shouldPlay: true)
                return
            }
            // Silent: if LMS is already playing us (it restarts a client that was
            // playing when it dropped it, e.g. a quick relaunch after a kill, or Siri
            // started something), the user is listening: unmute and leave it,
            // rather than jump to an old position and land paused.
            let generation = self.recoveryGeneration
            let statusCommand: [String: Any] = [
                "id": 1,
                "method": "slim.request",
                "params": [self.settings.playerMACAddress, ["status", "-", 1]]
            ]
            self.sendJSONRPCCommandDirect(statusCommand, timeout: 2.0) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self, self.recoveryGeneration == generation, self.isRecoveryInProgress else { return }
                    let mode = (response["result"] as? [String: Any])?["mode"] as? String
                    if mode == "play" && !self.forcePausedRestore {
                        os_log(.info, log: self.logger, "[APP-RECOVERY] 🔄 Server is already playing us - not restoring paused")
                        self.isRecoveryInProgress = false
                        self.silentRecoveryPauseGeneration = nil
                        self.audioManager.disableSilentRecoveryMode()
                        return
                    }
                    self.forcePausedRestore = false
                    self.executePlaylistRecovery(shouldPlay: false)
                }
            }
        }
    }

    /// An audible recovery must not play silently. If a silent recovery's
    /// mute is still engaged, this recovery superseded it (generation bump)
    /// and its settle paths are all dead — fully unmute here. Otherwise
    /// just lift the app-open pre-mute (bd 34l).
    private func liftPreMuteForAudibleRecovery() {
        // A forgotten-player restart over downloaded copies stays muted until
        // our correction jump lands (device test 2026-10-18: lifting it on
        // "server already restarted" played the wrong song for 1.6s).
        guard !lifeboatRestartMuted else { return }
        if audioManager.isSilentRecoveryMuted {
            audioManager.disableSilentRecoveryMode()
        } else {
            audioManager.cancelPreMute(reason: "audible recovery")
        }
    }

    private func executePlaylistRecovery(shouldPlay: Bool) {
        os_log(.error, log: logger, "[APP-RECOVERY] 🎯 EXECUTING PLAYLIST RECOVERY (shouldPlay: %{public}s)", shouldPlay ? "YES" : "NO")

        // Capture this recovery's identity: closures below no-op if a newer
        // recovery has started by the time they fire.
        let generation = recoveryGeneration

        // CRITICAL FIX: Add timeout to prevent permanent recovery lock if JSONRPC callback fails
        // This prevents CarPlay "Resume Playback" from hanging on subsequent attempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self else { return }
            // Only clear OUR recovery. Without the generation check: recovery A
            // completes at t=3s, recovery B starts at t=8s (silent mute armed),
            // A's timer fires at t=10s → clears B's lock and unmutes B's
            // mid-establishment stream → audible burst.
            guard self.recoveryGeneration == generation else { return }
            if self.isRecoveryInProgress {
                os_log(.error, log: self.logger, "⚠️ RECOVERY TIMEOUT - Clearing lock after 10s (callback likely failed)")
                self.isRecoveryInProgress = false
                // Don't leave audio muted if the jump callback never fires — handlePendingRecovery(.appOpen)
                // sets the mute flags before this function runs, and only the success callback unmutes.
                // settle (not a bare disable): the server may have started the stream even though
                // the callback was lost, so a still-flowing muted stream needs the local pause +
                // server-pause retry before gain is restored (bd 34l). No-op when mute isn't armed.
                self.awaitingSilentRecoveryUnmute = false
                self.settleSilentRecoveryAudio(reason: "recovery timeout")
            }
        }

        // NOTE: FLAC restriction removed - FLAC now uses legacy URL streaming (not push streams)
        // which supports seeking via server-side transcoding. Playlist jump recovery works for all formats.

        // Check if we have recovery data (no time limit - like other music players)
        let hasTimestamp = UserDefaults.standard.object(forKey: "lyrplay_recovery_timestamp") != nil
        let savedIndex = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int
        let savedPosition = UserDefaults.standard.double(forKey: "lyrplay_recovery_position")
        let isAudibleRetry = shouldPlay && outageHoldActive && audibleRecoveryTarget != nil

        // Position saved but the index is gone (a jump that just succeeded
        // deletes all three keys; later saves write only position +
        // timestamp). A plain play/pause would lose the position: on a
        // stopped player play starts the track at 0:00, and on a player LMS
        // thinks is playing it does nothing (Commands.pm playcontrolCommand).
        // Ask LMS which track it's on and jump there (bd 27ye).
        if Self.needsServerRecoveryIndex(hasTimestamp: hasTimestamp, hasIndex: savedIndex != nil,
                                         position: savedPosition, isAudibleRetry: isAudibleRetry) {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔍 Recovery index missing - asking server for the current track")
            let statusCommand: [String: Any] = [
                "id": 1,
                "method": "slim.request",
                "params": [settings.playerMACAddress, ["status", "-", 1]]
            ]
            sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self, self.recoveryGeneration == generation, self.isRecoveryInProgress else { return }
                    let index = Self.serverRecoveryIndex(fromStatus: response["result"] as? [String: Any])
                    if let index = index {
                        self.setRecoveryIndexFromServer(index)
                    } else {
                        os_log(.error, log: self.logger, "[APP-RECOVERY] 🔍 No server index (status failed or empty playlist)")
                    }
                    self.continuePlaylistRecovery(
                        saved: index.map { RecoveryTarget(index: $0, position: savedPosition) },
                        shouldPlay: shouldPlay, isAudibleRetry: isAudibleRetry, generation: generation)
                }
            }
            return
        }

        let saved = Self.savedRecoveryTarget(hasTimestamp: hasTimestamp, index: savedIndex, position: savedPosition)
        continuePlaylistRecovery(saved: saved, shouldPlay: shouldPlay, isAudibleRetry: isAudibleRetry, generation: generation)
    }

    /// Ask LMS for the track index only when there's a position to resume
    /// but no index, and no kept outage target (build 9) to use instead.
    static func needsServerRecoveryIndex(hasTimestamp: Bool, hasIndex: Bool, position: Double, isAudibleRetry: Bool) -> Bool {
        hasTimestamp && !hasIndex && position > 0 && !isAudibleRetry
    }

    /// LMS's current track index from a status result, or nil when the query
    /// failed or the playlist is empty.
    static func serverRecoveryIndex(fromStatus result: [String: Any]?) -> Int? {
        guard let result = result else { return nil }
        let tracks = (result["playlist_tracks"] as? Int) ?? Int(result["playlist_tracks"] as? String ?? "") ?? 0
        guard tracks > 0 else { return nil }
        return playlistIndex(fromStatus: result)
    }

    /// The rest of executePlaylistRecovery, once the saved target is known.
    private func continuePlaylistRecovery(saved: RecoveryTarget?, shouldPlay: Bool, isAudibleRetry: Bool, generation: Int) {
        guard let target = Self.resolveRecoveryTarget(saved: saved, kept: audibleRecoveryTarget, isAudibleRetry: isAudibleRetry) else {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔄 No recovery data - using simple %{public}s command", shouldPlay ? "play" : "pause")
            finishRecoveryWithoutJump(shouldPlay: shouldPlay)
            return
        }
        if isAudibleRetry {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔁 Retrying this outage's jump target: track %d at %.2f", target.index, target.position)
        }

        let savedIndex = target.index
        let savedPosition = target.position

        guard savedPosition > 0 else {
            os_log(.error, log: logger, "[APP-RECOVERY] 🔄 No saved position - using simple %{public}s command", shouldPlay ? "play" : "pause")
            finishRecoveryWithoutJump(shouldPlay: shouldPlay)
            return
        }

        if shouldPlay && outageHoldActive {
            audibleRecoveryTarget = target
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
            liftPreMuteForAudibleRecovery()
        }

        // We chose the resume position, so display it immediately and hold it while
        // the server's play point is poisoned (see suppressServerTimePollsUntil).
        // Seed BEFORE the jump so no poll race can paint the spike first.
        simpleTimeTracker.updateFromServer(time: savedPosition, playing: shouldPlay)
        suppressServerTimePollsUntil = Date().addingTimeInterval(3.0)
        holdTimeUntilRecoveryJump = false
        os_log(.info, log: logger, "⏱️ Seeded time tracker at %.2f, suppressing server-time polls for 3s", savedPosition)

        // Arm the pause before the jump: the stream can start before its reply arrives.
        if !shouldPlay {
            silentRecoveryPauseGeneration = generation
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
            // URLSession invokes this on a background thread — hop to main, where
            // all recovery state lives.
            DispatchQueue.main.async {
                guard let self = self else { return }

                // A stale completion (our 10s timeout already released the lock and a
                // newer recovery took over) must not clear the newer recovery's lock,
                // run the pause dance against its stream, or delete its recovery data.
                guard self.recoveryGeneration == generation else {
                    os_log(.error, log: self.logger, "🔒 Ignoring stale playlist-jump completion (gen %d, current %d)", generation, self.recoveryGeneration)
                    return
                }

                // sendJSONRPCCommandDirect reports a network failure / timeout as
                // an empty response. Don't treat that as success: keep the saved
                // position and try again (bd 6lvg — the old code deleted it, so a
                // jump lost to an outage left nothing to recover to).
                guard response["result"] != nil else {
                    os_log(.error, log: self.logger, "[APP-RECOVERY] ❌ Playlist jump failed (no server response) - keeping recovery data")
                    self.isRecoveryInProgress = false
                    if shouldPlay {
                        self.retryAudibleRecovery(reason: "jump failed")
                    } else {
                        self.silentRecoveryPauseGeneration = nil
                        self.awaitingSilentRecoveryUnmute = false
                        self.settleSilentRecoveryAudio(reason: "jump failed")
                    }
                    return
                }

                os_log(.info, log: self.logger, "🎯 Playlist jump recovery completed")

                // Silent recovery pauses as soon as its muted stream plays
                // (handleDecoderDidStartPlayback, push streams). Other streams don't
                // report it, so also watch the player state.
                if !shouldPlay {
                    os_log(.info, log: self.logger, "⏸️ App foreground recovery: pausing once the silent stream plays")
                    self.pauseSilentRecoveryWhenPlaying(generation: generation, checksLeft: 16)
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
    }

    // MARK: - Unified Recovery Handler (LMS_StreamTest-6lb)

    /// Handle pending recovery based on trigger type - called from slimProtoDidConnect()
    /// This is the SINGLE entry point for all recovery scenarios, preventing conflicts
    func handlePendingRecovery() {
        let trigger = pendingRecoveryTrigger
        pendingRecoveryTrigger = .none  // Reset immediately to prevent double-execution

        // Offline playback (copies or offline buttons): the lifeboat jump moves LMS
        // to us. A second recovery from saved data would fight it (review H3).
        if offlinePlaybackOwnsRecovery, trigger == .appOpen || trigger == .lockScreen {
            os_log(.info, log: logger, "🛟 %{public}s recovery: offline playback owns it - moving LMS to us instead",
                   String(describing: trigger))
            audioManager.cancelPreMute(reason: "offline playback owns recovery")
            if connectionIsLive { jumpLMSToLifeboatPosition() }
            return
        }

        switch trigger {
        case .appOpen:
            // App open recovery: muted + paused (unique silent recovery feature)
            guard settings.enableAppOpenRecovery else {
                os_log(.info, log: logger, "🔇 App open recovery: disabled in settings - skipping")
                return
            }
            // Left by builds that gated recovery on background time; nothing reads it now.
            UserDefaults.standard.removeObject(forKey: "lyrplay_backgrounded_at")

            // Double-trigger suppression (bd 34l, captured in device log): the
            // background reconnect timer can race the foreground wake and fire a
            // .networkRestored recovery first. It performs the same silent
            // jump→pause for a paused session — running a second recovery here
            // consumed no data (the first ate it), bumped the generation (killing
            // the first one's pause dance), and bare-unmuted its playing stream.
            // LMS restarted a stream for us on reconnect (it was playing when we
            // were dropped, e.g. a quick relaunch after a kill): leave it playing.
            // (Recently: on a long-lived connection the original stream started on it too.)
            if serverStartedStreamSinceConnect && serverStartedStreamRecently {
                os_log(.info, log: logger, "🔇 App open recovery: server already restarted the stream - skipping")
                audioManager.cancelPreMute(reason: "server restarted stream")
                return
            }

            // An outage hold is already getting playback back (audibly); landing
            // paused on top of it would undo that.
            guard !outageHoldActive else {
                os_log(.info, log: logger, "🔇 App open recovery: outage hold active - it owns playback, skipping")
                audioManager.cancelPreMute(reason: "outage hold active")
                return
            }

            // silentRecoveryOwnsMute also covers a silent recovery that's waiting for
            // the server or for its pause: enableSilentRecoveryMode below would flush
            // that one's muted stream.
            guard !isRecoveryInProgress, !silentRecoveryOwnsMute else {
                os_log(.info, log: logger, "🔇 App open recovery: another recovery already in flight - skipping duplicate")
                return
            }

            // Nothing to recover when audio is actively playing (bd 261, captured
            // device log): opening the phone app during a live CarPlay session
            // cold-launches ContentView, whose recovery gate checks duration/data
            // but not player state — the jump then stops live playback for ~1s
            // and rewinds to a stale saved position. The warm-resume path already
            // skips on Playing; enforce it here so every entry path inherits it.
            if audioManager.getPlayerState() == "Playing" {
                os_log(.info, log: logger, "🔊 App open recovery: already playing - skipping (nothing to recover)")
                audioManager.cancelPreMute(reason: "already playing")
                return
            }

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

            // No settle delay: performPlaylistRecovery waits until the server has
            // talked on this connection (serverHeardRecently), which is what matters.
            performPlaylistRecovery(shouldPlay: false)

        case .lockScreen:
            // Lock screen recovery: not muted + playing
            os_log(.info, log: logger, "🔊 Lock screen recovery: playing")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                // A pause meanwhile ended the hold: don't start playing anyway.
                guard self.outageHoldActive else {
                    os_log(.info, log: self.logger, "🔊 Lock screen recovery: paused meanwhile - not playing")
                    return
                }
                self.performPlaylistRecovery(shouldPlay: true)
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
                guard let self = self else { return }
                // LMS restarts a known playing client itself right after HELO.
                // Jumping on top of that collides; let the server's restart run
                // and the outage-hold watchdog retry if it doesn't produce audio.
                if shouldPlay && self.serverStartedStreamSinceConnect {
                    os_log(.info, log: self.logger, "🔄 Network restored: server already restarted the stream - skipping jump")
                    self.liftPreMuteForAudibleRecovery()
                    if self.client.lastHeloWasReconnect { self.correctForgottenRestart() }
                    return
                }
                if self.client.lastHeloWasReconnect && !self.serverStartedStreamSinceConnect {
                    self.continueAfterReconnectHelo(shouldPlay: shouldPlay)
                    return
                }
                guard shouldPlay else {
                    self.performPlaylistRecovery(shouldPlay: false)
                    return
                }
                self.unlessPausedOnServer {
                    self.performPlaylistRecovery(shouldPlay: true)
                }
            }

        case .none:
            // A reconnect that came from the network monitor rather than the
            // connection manager sets no trigger, but an outage hold means
            // playback was interrupted: check it like a network-restored one.
            if client.lastHeloWasReconnect && outageHoldActive {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self else { return }
                    if self.serverStartedStreamSinceConnect {
                        self.correctForgottenRestart()
                        return
                    }
                    guard self.outageHoldActive else { return }
                    self.continueAfterReconnectHelo(shouldPlay: true)
                }
                return
            }
            // No recovery needed - normal connect (e.g., initial app launch)
            os_log(.info, log: logger, "📡 Normal connect - no recovery needed")
        }
    }
}

// MARK: - SlimProtoClientDelegate
extension SlimProtoCoordinator: SlimProtoClientDelegate {
    
    func slimProtoShouldHeloReconnect() -> Bool {
        // In a sync group LMS doesn't restart a reconnecting member (restoreSync),
        // so our buffer would play on out of sync with the others: keep the fresh HELO.
        let reconnect = settings.loadSyncGroupID() == nil && Self.heloShouldReconnect(
            enabled: settings.seamlessReconnect,
            sameServerAsSession: sessionServer == currentSessionServer,
            // Offline playback: we still hold the session even when stopped
            // (copies ran out) or with an app-open trigger (review H3).
            trigger: offlinePlaybackOwnsRecovery ? .none : pendingRecoveryTrigger,
            playerState: audioManager.getPlayerState(),
            stalled: audioManager.isPushStreamStalled(),
            outageHold: outageHoldActive || offlinePlaybackOwnsRecovery)
        if lifeboatUsed {
            // Their track events describe what we played offline, not what LMS has.
            client.discardHeldEvents()
        }
        reconnectTargetFromLifeboat = lifeboatUsed
        reconnectTarget = (reconnect && (outageHoldActive || lifeboatUsed)) ? Self.savedRecoveryTarget(
            hasTimestamp: true,
            index: UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int,
            position: getCurrentTimeForSaving()) : nil
        os_log(.info, log: logger, "🤝 HELO: %{public}s (trigger %{public}s, player %{public}s, hold %{public}s)",
               reconnect ? "reconnect - LMS keeps the session" : "fresh",
               String(describing: pendingRecoveryTrigger), audioManager.getPlayerState(),
               outageHoldActive ? "ON" : "OFF")
        return reconnect
    }

    func slimProtoDidConnect() {
        os_log(.info, log: logger, "✅ Connection established")
        lastConnectedAt = Date()
        serverUnreachableSince = nil
        audibleRecoveryRetries = 0  // retry budget is per connection (bd 6lvg)
        connectionManager.didConnect()
        syncControllerReset(reason: "slimProtoDidConnect")

        // Don't start any status timers here
        // Heartbeat only starts during playback

        setupNowPlayingManagerIntegration()

        // Apply tvOS volume policy if user opted in (fixOutputAt100Percent).
        // Disables LMS software volume attenuation and forces volume to 100%.
        applyFixedOutputPolicyIfNeeded()

        // Radio: make LMS proxy internet streams for our player (GH #97).
        applyProxiedStreamingPolicy()

        let reconnectHelo = client.lastHeloWasReconnect
        sessionServer = currentSessionServer

        // UNIFIED RECOVERY: Handle based on trigger type (LMS_StreamTest-6lb)
        // This replaces separate recovery calls in ContentView and sendLockScreenCommand
        handlePendingRecovery()

        if lifeboatUsed || lifeboatPausedLocally {
            // Offline we played copies or used the buttons: LMS has to come to us,
            // whatever recovery trigger this connect has (a pause offline ends the hold).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, self.lifeboatUsed || self.lifeboatPausedLocally, self.serverHeardRecently else { return }
                self.clearHeldTrackEnd()
                self.jumpLMSToLifeboatPosition()
            }
        }

        if reconnectHelo && decodeEndHeld {
            resolveHeldTrackEnd()
        } else if !reconnectHelo {
            clearHeldTrackEnd()  // LMS restarts the stream or we recover: the held end means nothing now
        }

        // Notify observers (CarPlay uses this for event-driven data loading)
        NotificationCenter.default.post(name: .slimProtoDidConnect, object: nil)
    }

    func slimProtoDidDisconnect(error: Error?) {
        os_log(.info, log: logger, "🔌 Connection lost")
        serverUnreachableSince = serverUnreachableSince ?? Date()

        // UNIFIED RECOVERY: Capture playback state for networkRestored recovery (LMS_StreamTest-6lb)
        let playerState = audioManager.getPlayerState()
        // "Buffering" = stalled waiting for data, still meant to be playing. An
        // active outage hold means a previous drop interrupted playback we're
        // still trying to resume (bd 6lvg).
        wasPlayingBeforeDisconnect = (playerState == "Playing" || playerState == "Buffering"
                                      || audioManager.isPushStreamStalled() || outageHoldActive)
        wasPausedBeforeDisconnect = (playerState == "Paused") && !wasPlayingBeforeDisconnect
        os_log(.info, log: logger, "📊 Disconnect state: wasPlaying=%{public}s, wasPaused=%{public}s (player: %{public}s, hold: %{public}s)",
               wasPlayingBeforeDisconnect ? "YES" : "NO", wasPausedBeforeDisconnect ? "YES" : "NO",
               playerState, outageHoldActive ? "ON" : "OFF")
        if wasPlayingBeforeDisconnect && !connectionManager.isUserInitiatedDisconnect {
            beginOutageHold(reason: "connection lost while playing")
        }

        // UNIFIED RECOVERY: Save position immediately (don't wait for timer)
        // Use interpolated server time (not decoder position) for accurate recovery
        let position = getCurrentTimeForSaving()
        if position > 0 {
            UserDefaults.standard.set(position, forKey: "lyrplay_recovery_position")
            UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
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
    }
    
    func slimProtoDidReceiveCommand(_ command: SlimProtoCommand) {
        // Record that we received a command (shows connection is alive)
        let silence = lastServerMessageAt.map { Date().timeIntervalSince($0) } ?? 0
        lastServerMessageAt = Date()
        if offlinePlaybackOwnsRecovery && silence > Self.liveConnectionWindow {
            // The socket never dropped (no reconnect will run), but we played or
            // paused offline meanwhile: move LMS to us now (review M4).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, self.offlinePlaybackOwnsRecovery, self.connectionIsLive else { return }
                self.jumpLMSToLifeboatPosition()
            }
        }
        connectionManager.recordHeartbeatResponse()

        // A decode end held while the connection was quiet but never dropped:
        // the server is talking again, so settle it now (no reconnect will).
        if decodeEndHeld && !resolvingHeldTrackEnd {
            resolveHeldTrackEnd()
        }

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

        connectKeepingFreshSocket()
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

    /// Sets LMS "Streaming Method" to Proxied Streaming (`mp3StreamingMethod=1`)
    /// for our own player on every connect (GH #97, forum DI.fm report).
    ///
    /// With Direct Streaming (the LMS default), plain-http radio is sent as a
    /// strm whose server IP/port is the radio station, and squeezelite connects
    /// there. LyrPlay always fetches the strm path from the LMS host
    /// (`extractURLFromHTTPRequest`), so direct streams fail and the server sits
    /// at "play 0:00". Proxied makes LMS fetch the station and relay it, the same
    /// path HTTPS radio already takes. Synced players are always proxied anyway.
    ///
    /// On a brand-new player the request can land before LMS has processed our
    /// HELO; LMS then drops the connection with no reply, so retry a few times.
    private func applyProxiedStreamingPolicy(attempt: Int = 1) {
        let playerID = settings.playerMACAddress
        guard !playerID.isEmpty else { return }

        let prefCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playerpref", "mp3StreamingMethod", "1"]]
        ]

        sendJSONRPCCommandDirect(prefCommand) { [weak self] result in
            guard let self = self else { return }
            if result["result"] != nil {
                os_log(.info, log: self.logger, "📻 Streaming method set to proxied (attempt %d)", attempt)
                return
            }
            guard attempt < 3 else {
                os_log(.error, log: self.logger, "📻 Could not set proxied streaming after %d attempts - plain-http radio may not play", attempt)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.applyProxiedStreamingPolicy(attempt: attempt + 1)
            }
        }
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
    
    func connectionManagerNetworkPathChanged() {
        os_log(.info, log: logger, "🌐 Network path changed - the next connect replaces the socket")
        client.markSocketStale()
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
        lastServerStreamStartAt = Date()
        clearHeldTrackEnd()
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
        lastServerStreamStartAt = Date()
        clearHeldTrackEnd()
        currentStreamFormat = format
        lastStreamReplayGain = replayGain
        if settings.lifeboatMode == 0 && !lifeboatCacheCleared {
            lifeboatCacheCleared = true
            lifeboat.removeAll()  // switched off: don't keep copies around
        }
        muteForgottenRestartOverCopies()
        if lifeboatActive || lifeboatUsed {
            os_log(.info, log: logger, "🛟 LMS is streaming again - leaving the downloaded copies")
        }
        lifeboatActive = false
        lifeboatUsed = false
        lifeboatPausedLocally = false
        forcePausedRestore = false
        savedMusicStartedOffline = false
        if !outageHoldActive { connectionManager.persistForPlayback = false }
        scheduleLifeboatPlan(after: 3)
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
        audioManager.startPushStreamPlayback(url: url, format: format, replayGain: replayGain, isGapless: isGapless, startTime: startTime, waitForUnpause: waitForUnpause)

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
        endOutageHold(reason: "paused")
        // Paused on purpose (Material, another controller): don't treat the
        // missing audio as a failed resume.
        DispatchQueue.main.async { [weak self] in self?.resumeInPlaceCheck = nil }

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

        // STMr is sent by the command handler (handleUnpauseCommand) — one
        // owner per protocol reply. bd LMS_StreamTest-433.3.3
    }

    func didStopStream() {
        os_log(.info, log: logger, "⏹️ Server stop command")
        // LMS's forgotten-player restart is q then s: decide before the flags clear.
        muteForgottenRestartOverCopies()
        clearHeldTrackEnd()
        lifeboatActive = false
        lifeboatUsed = false
        savedMusicStartedOffline = false
        DispatchQueue.main.async { [weak self] in self?.resumeInPlaceCheck = nil }

        let shownPosition = getCurrentInterpolatedTime().time
        let reconnectStop = Self.isReconnectStop(
            connectedFor: lastConnectedAt.map { Date().timeIntervalSince($0) },
            localState: audioManager.getPlayerState(),
            shownPosition: shownPosition,
            savedPosition: UserDefaults.standard.double(forKey: "lyrplay_recovery_position"))

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
        // Skipped during a recovery window: the server sends strm 'q' as part of executing
        // the playlist jump, and zeroing here would repaint the lock screen at 0:00 until
        // the window closes — the "backward" leg of the timer-hunting bug.
        if serverTimeUpdatesSuppressed() {
            os_log(.info, log: logger, "⏱️ Skipping time reset on strm 'q' during recovery window")
        } else if reconnectStop {
            // Play recovers to the saved position, so show that instead of 0:00.
            os_log(.info, log: logger, "⏱️ Reconnect stop while paused - lock screen stays at %.2f", shownPosition)
            updateServerTime(position: shownPosition, isPlaying: false)
        } else {
            updateServerTime(position: 0.0, duration: 0.0, isPlaying: false)
        }

        // Stop periodic server time fetching
        stopServerTimeFetching()

        // Stop heartbeat when stopped
        stopPlaybackHeartbeat()

        // Stop radio metadata refresh poll
        stopRadioMetadataRefreshTimer()

        // Note: ICY metadata callbacks are handled automatically by BASS

        // STMf is sent by the command handler (handleStopCommand/
        // handleFlushCommand) — one owner per protocol reply. bd LMS_StreamTest-433.3.3
    }

    // MARK: - Gapless Playback - Track Decode Complete

    /// Send STMd message when decoder completes naturally (like squeezelite DECODE_COMPLETE)
    /// This tells the server the track finished decoding and triggers next track queueing
    func sendTrackDecodeComplete(mayHold: Bool = true) {
        if mayHold && settings.seamlessReconnect && handleDownloadEnd() {
            return
        }
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
    func sendTrackDecodeError(keepGaplessQueue: Bool = false) {
        // A gapless start that failed to open pushed nothing: the previous
        // track's tail is still playing. After STMn in PLAYING the server
        // sends the replacement strm 's' with no 'q' first (_SyncStopNext),
        // so re-arm the gapless flag (set BEFORE STMn, same race as STMd) —
        // otherwise the replacement is treated as a manual skip and flushes
        // the tail (GH #102). A real skip still sends 'q', which clears it.
        if keepGaplessQueue {
            expectingGaplessTransition = true
            os_log(.error, log: logger, "🎵 Failed gapless start - keeping buffered audio for the server's replacement track")
        }
        os_log(.error, log: logger, "❌ Track decode error - sending STMn to server")
        client.sendStatus("STMn")
    }

    /// Send STMu when the output buffer drains after a natural decode completion —
    /// squeezelite's output-underrun signal (slimproto.c:716). The server maps it
    /// to its Stopped event: end-of-playlist → clean stop (strm 'q'); next track
    /// still being prepared → plays it when ready. bd LMS_StreamTest-nzj
    func sendPlaybackComplete() {
        if decodeEndHeld {
            drainHeld = true
            os_log(.info, log: logger, "📬 Output drained after a held decode end - holding STMu too")
            return
        }
        os_log(.info, log: logger, "🏁 Playback complete (output drained) - sending STMu to server")
        client.sendStatus("STMu")
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
        bumpRecoveryIndexAtBoundary()

        // CRITICAL FIX: Reset SimpleTimeTracker to 0 when new track starts
        // This ensures lock screen shows 0:00 for the new track, not stale time from previous track
        simpleTimeTracker.updateFromServer(time: 0.0, duration: 0.0, playing: true)
        os_log(.info, log: logger, "[BOUNDARY-DRIFT] 🔄 Reset SimpleTimeTracker to 0.0 for new track start")

        if lifeboatActive, let index = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int,
           let track = lifeboat.track(at: index) {
            // Offline: LMS can't tell us what's playing.
            audioManager.updateTrackMetadata(title: track.title, artist: track.artist, album: track.album,
                                             artworkURL: nil, duration: track.duration)
            os_log(.info, log: logger, "🛟 Now playing the downloaded copy of track %d: %{public}s", index, track.title)
        } else {
            scheduleLifeboatPlan(after: 2)
        }

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

    /// Real STAT buffer/byte telemetry for status packets (bd LMS_StreamTest-433.4.3).
    func getStatTelemetry() -> SlimProtoStatTelemetry {
        return audioManager.statTelemetry()
    }

    func hasActiveStream() -> Bool {
        // Check if we have an active BASS stream (not stale after reconnect)
        // This includes both URL streams (audioPlayer) and push streams (streamDecoder)
        let playerState = audioManager.getPlayerState()
        let hasPushStream = audioManager.hasPushStream()
        return playerState != "No Stream" || hasPushStream
    }

    func didReceiveStatusRequest() {
        // Bookkeeping only. The command handler owns the protocol reply — it
        // sends STMt/STMp WITH the server-timestamp echo (LMS uses the echo
        // for playPoint/RTT in sync groups). Sending a second, timestamp-less
        // STAT from here doubled STAT volume and perturbed the sync math.
        // bd LMS_StreamTest-433.3.3
        connectionManager.recordHeartbeatResponse()
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

    /// Parse the sync-group ID out of a serv payload. Real LMS layout
    /// (slimserver/Slim/Control/Commands.pm:312): `pack 'NA10'` = 4-byte server
    /// IP + 10 ASCII digits when the player is in a sync group, or `pack 'N'` =
    /// bare 4-byte IP when not. (The old parser expected an invented
    /// IP+HTTP-port+CLI-port+group layout ≥18 bytes that never matched, so the
    /// group was never saved. bd LMS_StreamTest-433.4.2)
    /// Returns nil when there is no group; "0000000000" is the unset pref.
    static func syncGroup(fromServPayload payload: Data) -> String? {
        guard payload.count >= 14 else { return nil }
        let idData = payload.subdata(in: 4..<14)
        guard let id = String(data: idData, encoding: .ascii),
              id.count == 10,
              id.allSatisfy({ $0.isNumber }),
              id != "0000000000" else { return nil }
        return id
    }

    /// Parse serv packet and extract sync group ID for multi-room persistence
    private func handleServPacket(_ payload: Data) {
        guard payload.count >= 4 else {
            os_log(.error, log: logger, "⚠️ serv packet too short: %d bytes (expected >= 4)", payload.count)
            return
        }

        if let group = Self.syncGroup(fromServPayload: payload) {
            os_log(.info, log: logger, "🔗 Sync group ID received: %{public}s", group)
            syncGroupID = group
            settings.saveSyncGroupID(group)
        } else {
            // No sync group - clear stored value
            os_log(.info, log: logger, "🔗 No sync group (player not synced)")
            syncGroupID = nil
            settings.clearSyncGroupID()
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
        
        guard let url = URL(string: settings.buildURLString(path: "/jsonrpc.js")) else {
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
        
        URLSession.lms.dataTask(with: request) { [weak self] data, response, error in
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

            // During a playlist-jump recovery the server's reported time is
            // poisoned by our own stale STATs (startOffset + dead stream's
            // elapsed). The tracker was seeded with the true resume position
            // when the jump was issued — hold it until the window closes.
            if serverTimeUpdatesSuppressed() {
                os_log(.info, log: logger, "⏱️ Ignoring server-time poll during recovery window (server=%.2f)", serverTime)
                return
            }

            // A player LMS has marked disconnected has a frozen time (where the
            // outage began) while our buffer plays on. Taking it would rewind
            // the tracker, and a recovery would jump back to it.
            if lifeboatUsed || outageHoldActive {
                // Through an outage our tracker is the truth (frozen where the
                // audio stopped, or following local audio) until playback from
                // the server resumes and ends the hold. Right after a reconnect
                // LMS's time is our drained stream's 0 (rig O4) or stale (O9:
                // 260s replaced our paused 42.8s), and a recovery would jump there.
                os_log(.info, log: logger, "⏱️ Ignoring server-time poll during the outage (server=%.2f)", serverTime)
                return
            }
            if Self.statusPlayerConnected(result) != true {
                os_log(.info, log: logger, "⏱️ Ignoring server-time poll: LMS has us disconnected (frozen time %.2f)", serverTime)
                return
            }

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
            // Stale-guarded: a poll response predating a gapless boundary must
            // not rewind the locally-incremented index (bd LMS_StreamTest-433.5.4).
            if let serverIndex = result["playlist_cur_index"] as? Int {
                setRecoveryIndexFromServer(serverIndex)
            } else if let serverIndexString = result["playlist_cur_index"] as? String,
                      let serverIndex = Int(serverIndexString) {
                setRecoveryIndexFromServer(serverIndex)
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
    
    /// LMS stops a paused player when it reconnects (Squeezebox.pm reconnect:
    /// "If we were paused, then stop"), right after HELO. That stop isn't the
    /// user's: the paused position is still where Play will resume.
    /// (A player already stopped shows 0 and stays there: after any stop the
    /// local state still reads "Paused", so that alone doesn't say paused.)
    static func isReconnectStop(connectedFor: TimeInterval?, localState: String,
                                shownPosition: Double, savedPosition: Double) -> Bool {
        guard let connectedFor = connectedFor, connectedFor < 2.0 else { return false }
        return localState == "Paused" && shownPosition > 0 && savedPosition > 0
    }

    /// True while inside the post-jump recovery window during which server-derived
    /// time (polls, strm 'q' resets) must not overwrite the seeded tracker position.
    /// Clears the window lazily once it has expired. Main thread only.
    private func serverTimeUpdatesSuppressed() -> Bool {
        if holdTimeUntilRecoveryJump { return true }
        guard let until = suppressServerTimePollsUntil else { return false }
        if Date() < until { return true }
        suppressServerTimePollsUntil = nil
        return false
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

        // A user pause/stop ends any attempt to resume playback (bd 6lvg).
        if command.lowercased() == "pause" || command.lowercased() == "stop" {
            endOutageHold(reason: "user \(command.lowercased())")
            resumeInPlaceCheck = nil
            remotePlayIntent = nil
        }

        // Save position on pause commands (creates save point for future recovery)
        if command.lowercased() == "pause" {
            // Local save first (instant, survives network transitions like CarPlay disconnect)
            let position = getCurrentTimeForSaving()
            if position > 0 {
                UserDefaults.standard.set(position, forKey: "lyrplay_recovery_position")
                UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
            }
            // Server roundtrip overwrites with authoritative data if reachable
            saveCurrentPositionForRecovery()
            os_log(.info, log: logger, "💾 Saved position on pause command for future recovery")
        }

        if handleOfflineCommand(command.lowercased()) { return }

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
            // The user wants audio: a silent recovery's pause re-sends must stop.
            silentPauseResendCancelled = true
            if takeOverSilentRecoveryForUserPlay() {
                return
            }
            let intent = UUID()
            remotePlayIntent = intent
            decideResumeRoute { [weak self] route in
                // A pause or stop pressed while we asked LMS wins.
                guard let self = self, self.remotePlayIntent == intent else { return }
                self.remotePlayIntent = nil
                // A silent recovery may have started while we asked (app came forward).
                if self.takeOverSilentRecoveryForUserPlay() {
                    return
                }
                if route == .resumeInPlace || route == .leaveAlone {
                    // LMS still has our paused stream: a plain unpause resumes it
                    // instantly from the buffer.
                    os_log(.info, log: self.logger, "🔒 Lock screen PLAY: resuming in place")
                    self.sendJSONRPCCommand("play")
                    self.checkResumedInPlace()
                } else {
                    os_log(.info, log: self.logger, "🔄 Lock screen PLAY: reconnect if needed + recover")
                    self.startLockScreenRecovery()
                }
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

    /// A user play during a silent (app-open) recovery takes it over: the silent
    /// pause would otherwise land on top of it. If the jump already went out the
    /// stream is at the saved position, so unmute and play; if it's still
    /// waiting, cancel it and let the normal play route recover audibly.
    /// Returns true when the play has been handled.
    private func takeOverSilentRecoveryForUserPlay() -> Bool {
        guard silentRecoveryOwnsMute else { return false }
        let jumpSent = silentRecoveryPauseGeneration != nil || awaitingSilentRecoveryUnmute
        // An audible recovery holds the lock (a silent one's leftover arm is all
        // that's left): clear the leftovers, never its lock or generation.
        if isRecoveryInProgress && !currentRecoveryIsSilent {
            silentRecoveryPauseGeneration = nil
            awaitingSilentRecoveryUnmute = false
            silentRecoveryWaiting = false
            audioManager.disableSilentRecoveryMode()
            return false
        }
        os_log(.info, log: logger, "🔒 Lock screen PLAY: taking over the silent recovery (jump sent: %{public}s)",
               jumpSent ? "yes" : "no")
        recoveryGeneration += 1   // its pause, re-sends and timers stand down
        silentRecoveryPauseGeneration = nil
        awaitingSilentRecoveryUnmute = false
        silentRecoveryWaiting = false
        isRecoveryInProgress = false
        audioManager.disableSilentRecoveryMode()
        guard jumpSent else {
            // Nothing streaming yet (its buffer was flushed): recover audibly.
            startLockScreenRecovery()
            return true
        }
        // The jump is out and its stream sits at the saved position: play it. Its
        // completion is now stale, so stay awake with the target in hand: the
        // hold's watchdog retries if that jump failed.
        beginOutageHold(reason: "user play took over silent recovery")
        if audibleRecoveryTarget == nil {
            audibleRecoveryTarget = Self.savedRecoveryTarget(
                hasTimestamp: UserDefaults.standard.object(forKey: "lyrplay_recovery_timestamp") != nil,
                index: UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int,
                position: UserDefaults.standard.double(forKey: "lyrplay_recovery_position"))
        }
        sendNormalJSONRPCCommand("play")
        return true
    }

    /// Reconnect and recover for a remote play: recovery runs from
    /// slimProtoDidConnect via the .lockScreen trigger.
    private func startLockScreenRecovery() {
        // (takeOverSilentRecoveryForUserPlay calls this after taking over, so
        // there is no silent owner left by then.)
        if silentRecoveryOwnsMute && takeOverSilentRecoveryForUserPlay() {
            return
        }
        // UNIFIED RECOVERY: Set trigger and let slimProtoDidConnect handle recovery (LMS_StreamTest-6lb)
        pendingRecoveryTrigger = .lockScreen

        // Stay awake until the reconnect + recovery gets audio going:
        // in the car the network may not be up yet (bd 8tjj).
        beginOutageHold(reason: "remote play, connection not live")

        let savedPosition = UserDefaults.standard.double(forKey: "lyrplay_recovery_position")
        if savedPosition > 0 && outageHoldActive {
            simpleTimeTracker.updateFromServer(time: savedPosition, playing: false)
            holdTimeUntilRecoveryJump = true
            os_log(.info, log: logger, "⏱️ Holding lock screen at %.2f until the recovery jump", savedPosition)
        }

        if connectionIsLive {
            // The connection is fine; LMS just doesn't hold our stream. Recover here.
            handlePendingRecovery()
            return
        }
        // Connected but quiet: possibly a zombie left by suspension, so replace it.
        // (A connecting socket is left alone: its didConnect runs the recovery.)
        if connectionManager.connectionState.isConnected {
            client.markSocketStale()
        }
        connect()
        // slimProtoDidConnect will call handlePendingRecovery()
    }

    /// A plain unpause should have audio within a moment. If it doesn't (the
    /// socket died just after the liveness check, or LMS had stopped the
    /// player), recover. Cancelled by any pause or stop meanwhile.
    private func checkResumedInPlace() {
        let check = UUID()
        resumeInPlaceCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self, self.resumeInPlaceCheck == check else { return }
            self.resumeInPlaceCheck = nil
            let state = self.audioManager.getPlayerState()
            guard state != "Playing", state != "Buffering",
                  !self.isRecoveryInProgress, self.pendingRecoveryTrigger == .none else { return }
            // Slow but on its way (LMS says play): leave it.
            let statusCommand: [String: Any] = [
                "id": 1,
                "method": "slim.request",
                "params": [self.settings.playerMACAddress, ["status", "-", 1]]
            ]
            self.sendJSONRPCCommandDirect(statusCommand, timeout: 2.0) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self, !self.isRecoveryInProgress, self.pendingRecoveryTrigger == .none else { return }
                    let mode = (response["result"] as? [String: Any])?["mode"] as? String
                    guard mode != "play", self.audioManager.getPlayerState() != "Playing" else { return }
                    os_log(.error, log: self.logger, "🔒 Lock screen PLAY: no audio 3s after resuming in place (server mode %{public}s) - recovering",
                           mode ?? "none")
                    self.startLockScreenRecovery()
                }
            }
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
        
        guard let url = URL(string: settings.buildURLString(path: "/jsonrpc.js")) else {
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

        let task = URLSession.lms.dataTask(with: request) { data, response, error in
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
        sendJSONRPCCommandDirect(jsonRPC, timeout: 5.0, completion: completion)
    }

    /// Same as above with a caller-chosen timeout, for server commands that hold
    /// the request open while they work (e.g. HitsPlaylist waits on Last.fm).
    public func sendJSONRPCCommandDirect(_ jsonRPC: [String: Any], timeout: TimeInterval, completion: @escaping ([String: Any]) -> Void) {
        os_log(.debug, log: logger, "🌐 Sending JSON-RPC command: %{public}s", String(describing: jsonRPC))

        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "❌ Failed to create JSON-RPC command")
            completion([:])
            return
        }

        // CRITICAL FIX: Use direct LMS endpoint instead of Material's /material/jsonrpc.js
        // Material endpoint can apply commands to wrong player based on Material UI session state
        // Direct endpoint ensures player MAC in params[0] is always respected
        let urlString = settings.buildURLString(path: "/jsonrpc.js")
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
        request.timeoutInterval = timeout
        
        let task = URLSession.lms.dataTask(with: request) { data, response, error in
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
        
        var request = URLRequest(url: URL(string: settings.buildURLString(path: "/jsonrpc.js"))!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0

        // Add HTTP Basic Authentication if configured
        if let authHeader = settings.generateAuthHeader() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.lms.dataTask(with: request) { data, response, error in
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
                    artworkURL = settings.absoluteServerURL(artwork)?.absoluteString
                } else if let coverid = firstTrack["coverid"] as? String, !coverid.isEmpty, coverid != "0" {
                    artworkURL = settings.absoluteServerURL("/music/\(coverid)/cover.jpg")?.absoluteString
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
    // MARK: - Reconnect HELO (ride out a network drop)

    private var currentSessionServer: String {
        "\(settings.activeServerHost):\(settings.activeServerSlimProtoPort)"
    }

    /// Whether a connect's HELO says "reconnect" (squeezelite sets it on every
    /// connect after the first). Only while we still hold the session: the
    /// same server, a track playing, paused or stalled locally, and no
    /// recovery that wants LMS's fresh-connect behaviour (app open and lock
    /// screen recoveries keep it, as tested in build 14).
    static func heloShouldReconnect(enabled: Bool, sameServerAsSession: Bool, trigger: RecoveryTrigger,
                                    playerState: String, stalled: Bool, outageHold: Bool) -> Bool {
        guard enabled, sameServerAsSession else { return false }
        switch trigger {
        case .networkRestored, .none: break
        default: return false
        }
        return playerState == "Playing" || playerState == "Paused" || stalled || outageHold
    }

    /// After a reconnect HELO LMS keeps our session and sends nothing. If the
    /// audio is still flowing from the buffer there is nothing to do; if it
    /// ran dry or the download was cut, jump to where we are (LMS won't
    /// restart on its own, so the jump can't collide with a server restart).
    /// A held decode end is settled by resolveHeldTrackEnd instead.
    private func continueAfterReconnectHelo(shouldPlay: Bool, attempt: Int = 0, generation: Int? = nil) {
        if lifeboatUsed && serverHeardRecently {
            clearHeldTrackEnd()
            jumpLMSToLifeboatPosition()
            return
        }
        guard !decodeEndHeld else { return }
        // Another recovery (the hold's watchdog, a user play) took over meanwhile.
        let generation = generation ?? recoveryGeneration
        guard generation == recoveryGeneration, !isRecoveryInProgress else { return }
        // Only a server that has answered on this connection has kept anything:
        // a socket can connect and drop again at once on a flaky path.
        guard serverHeardRecently else {
            guard attempt < 10, connectionManager.connectionState.isConnected else {
                os_log(.info, log: logger, "🔁 Reconnect HELO: server never answered on this connection - leaving it to the next reconnect")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.continueAfterReconnectHelo(shouldPlay: shouldPlay, attempt: attempt + 1, generation: generation)
            }
            return
        }
        if lifeboatUsed {
            clearHeldTrackEnd()
            jumpLMSToLifeboatPosition()
            return
        }
        if lifeboatActive && shouldPlay && audioManager.getPlayerState() == "Playing" {
            // Still on LMS's track, from its copy: LMS kept the session.
            confirmKeptSession()
            return
        }
        let stream = audioManager.pushStreamState()
        let intact = stream.connected || stream.completedNaturally
        let state = audioManager.getPlayerState()
        if !shouldPlay {
            if intact {
                os_log(.info, log: logger, "🔁 Reconnected: LMS kept our paused session - nothing to restore")
            } else {
                os_log(.info, log: logger, "🔁 Reconnected paused, but the download was cut - recovering")
                performPlaylistRecovery(shouldPlay: false)
            }
            return
        }
        if intact && state == "Playing" {
            confirmKeptSession()
            return
        }
        // A frozen download that came back can take a moment to refill a dry buffer.
        if intact && attempt < 13 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self, self.outageHoldActive else { return }
                self.continueAfterReconnectHelo(shouldPlay: true, attempt: attempt + 1, generation: generation)
            }
            return
        }
        os_log(.info, log: logger, "🔁 Reconnected, audio not flowing (state %{public}s, download %{public}s) - jump to our position",
               state, intact ? "open" : "cut")
        unlessPausedOnServer {
            self.performPlaylistRecovery(shouldPlay: true)
        }
    }

    /// What to do when our audio played on through the outage and LMS kept the
    /// session. LMS may have moved on meanwhile (another controller paused,
    /// stopped or changed the song while our socket was gone: its strm never
    /// reached us, and the reconnect bit means it won't restart us), so check
    /// before calling it kept.
    enum KeptSessionCheck: Equatable {
        case kept
        case pauseLocally      // LMS paused us
        case stopLocally       // LMS stopped us
        case followServer      // LMS is on another track: play what it has
    }

    static func keptSessionCheck(serverMode: String?, serverIndex: Int?, localIndex: Int?) -> KeptSessionCheck {
        switch serverMode {
        case "pause": return .pauseLocally
        case "stop": return .stopLocally
        default: break
        }
        if let server = serverIndex, let local = localIndex, server != local { return .followServer }
        return .kept
    }

    /// Ask LMS for its state; keep the session, or have LMS send its state
    /// again now that we're connected (its own commands re-issue the strm).
    private func confirmKeptSession() {
        let statusCommand: [String: Any] = [
            "id": 1, "method": "slim.request",
            "params": [settings.playerMACAddress, ["status", "-", 1]]
        ]
        sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self, self.outageHoldActive else { return }
                let result = response["result"] as? [String: Any]
                let mode = result?["mode"] as? String
                let index = Self.playlistIndex(fromStatus: result)
                let local = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int
                let check = Self.keptSessionCheck(serverMode: mode, serverIndex: index, localIndex: local)
                os_log(.info, log: self.logger, "🔁 Reconnected, audio never stopped; LMS: %{public}s track %{public}s (ours %{public}s) → %{public}s",
                       mode ?? "?", index.map(String.init) ?? "?", local.map(String.init) ?? "?", String(describing: check))
                switch check {
                case .kept:
                    self.endOutageHold(reason: "reconnected - session kept")
                case .pauseLocally:
                    self.endOutageHold(reason: "paused on the server meanwhile")
                    self.sendJSONRPCCommandDirect(["id": 1, "method": "slim.request",
                                                   "params": [self.settings.playerMACAddress, ["pause", "1"]]]) { _ in }
                case .stopLocally:
                    self.endOutageHold(reason: "stopped on the server meanwhile")
                    self.sendJSONRPCCommandDirect(["id": 1, "method": "slim.request",
                                                   "params": [self.settings.playerMACAddress, ["stop"]]]) { _ in }
                case .followServer:
                    guard let index = index else { return }
                    let time = (result?["time"] as? Double) ?? 0
                    let jump: [String: Any] = [
                        "id": 1, "method": "slim.request",
                        "params": [self.settings.playerMACAddress, [
                            "playlist", "jump", index, 1, 0, ["timeOffset": time]
                        ]]
                    ]
                    self.sendJSONRPCCommandDirect(jump) { _ in }   // the hold ends when that stream plays
                }
            }
        }
    }

    /// LMS restarted a forgotten player (after 300s it ignores the reconnect
    /// bit: resumeOnPower(1) jumps to the position it saved when we dropped).
    /// The audio played on from our buffer after that, so the restart is
    /// behind where the user stopped hearing it. Once LMS's own restart is
    /// playing, a jump to our target can't collide with it (it's an ordinary
    /// jump, like a seek from Material); same track only.
    static func forgottenRestartNeedsJump(serverIndex: Int?, serverTime: Double, mode: String?,
                                          target: RecoveryTarget, anyTrack: Bool = false,
                                          tolerance: Double = 5) -> Bool {
        guard mode == "play", let serverIndex = serverIndex else { return false }
        if serverIndex != target.index { return anyTrack }
        return abs(serverTime - target.position) > tolerance
    }

    /// LMS forgot us during the outage (> 300s) and restarts where it lost us
    /// (strm q, then s, right after the HELO), far behind the copies we
    /// played. Mute before the restart's stream is created; the correction
    /// jump to our place unmutes.
    private func muteForgottenRestartOverCopies() {
        guard !lifeboatRestartMuted, lifeboatUsed || lifeboatActive,
              client.lastHeloWasReconnect, reconnectTarget != nil,
              let connected = lastConnectedAt, Date().timeIntervalSince(connected) < 3 else { return }
        audioManager.enableSilentRecoveryMode()
        lifeboatRestartMuted = true
        liftLifeboatRestartMute(after: 8)  // ceiling, should the correction never run
        os_log(.info, log: logger, "🛟 LMS restarted a forgotten player over our downloaded copies - muted until we move it")
        // A pause offline ended the outage hold, so no recovery trigger will call it.
        if lifeboatPausedLocally { correctForgottenRestart() }
    }

    private func liftLifeboatRestartMute(after delay: TimeInterval = 0) {
        guard lifeboatRestartMuted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.lifeboatRestartMuted else { return }
            self.lifeboatRestartMuted = false
            self.audioManager.disableSilentRecoveryMode()
        }
    }

    private func correctForgottenRestart() {
        guard let target = reconnectTarget else { liftLifeboatRestartMute(); return }
        reconnectTarget = nil
        if lifeboatPausedLocally {
            // Paused on the phone while offline: land paused at our place (the
            // silent recovery mutes, jumps and pauses; it owns the mute now).
            os_log(.info, log: logger, "🔁 LMS forgot us while we were paused offline - restoring paused: track %d at %.1f",
                   target.index, target.position)
            lifeboatRestartMuted = false
            forcePausedRestore = true  // LMS's restart says "play": still land paused (review H5)
            UserDefaults.standard.set(target.index, forKey: "lyrplay_recovery_index")
            UserDefaults.standard.set(target.position, forKey: "lyrplay_recovery_position")
            UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
            performPlaylistRecovery(shouldPlay: false)
            return
        }
        let anyTrack = reconnectTargetFromLifeboat
        // Muted: no need to let the restart run long (it only has to be playing).
        DispatchQueue.main.asyncAfter(deadline: .now() + (lifeboatRestartMuted ? 1.5 : 3.0)) { [weak self] in
            guard let self = self else { return }
            let statusCommand: [String: Any] = [
                "id": 1, "method": "slim.request",
                "params": [self.settings.playerMACAddress, ["status", "-", 1]]
            ]
            self.sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard let result = response["result"] as? [String: Any] else { self.liftLifeboatRestartMute(); return }
                    let time = (result["time"] as? Double) ?? 0
                    let mode = result["mode"] as? String
                    let index = Self.playlistIndex(fromStatus: result)
                    guard Self.forgottenRestartNeedsJump(serverIndex: index, serverTime: time, mode: mode,
                                                         target: target, anyTrack: anyTrack) else {
                        self.liftLifeboatRestartMute()
                        os_log(.info, log: self.logger, "🔁 LMS restart at %.1f (track %{public}s, %{public}s) - no correction (target track %d at %.1f)",
                               time, index.map(String.init) ?? "?", mode ?? "?", target.index, target.position)
                        return
                    }
                    os_log(.info, log: self.logger, "🔁 LMS forgot us and restarted at %.1f - jumping to where the audio stopped: track %d at %.1f",
                           time, target.index, target.position)
                    self.simpleTimeTracker.updateFromServer(time: target.position, playing: true)
                    self.suppressServerTimePollsUntil = Date().addingTimeInterval(3.0)
                    let jump: [String: Any] = [
                        "id": 1, "method": "slim.request",
                        "params": [self.settings.playerMACAddress, [
                            "playlist", "jump", target.index, 1, 0, ["timeOffset": target.position]
                        ]]
                    ]
                    self.sendJSONRPCCommandDirect(jump) { [weak self] _ in
                        DispatchQueue.main.async { self?.liftLifeboatRestartMute(after: 1.0) }
                    }
                }
            }
        }
    }

    /// The held decode end was the real end of the track: the decoded audio
    /// reaches the track's duration (within `tolerance`). With the next track
    /// decoding, its decode started at 0, so its decoded seconds are track
    /// time; with the current one, the end is the playhead's track time plus
    /// the decoded audio still waiting to play. An unknown duration (radio)
    /// counts as an end, as before.
    static func heldDecodeEndWasTrackEnd(decodingAhead: Bool, decodedEndSeconds: Double?,
                                         trackTime: Double, bufferedSeconds: Double,
                                         currentDuration: Double, nextDuration: Double,
                                         tolerance: Double = 3.0) -> Bool {
        if decodingAhead {
            guard nextDuration > 0, let end = decodedEndSeconds else { return true }
            return end >= nextDuration - tolerance
        }
        guard currentDuration > 0 else { return true }
        return trackTime + bufferedSeconds >= currentDuration - tolerance
    }

    /// Settle a held decode end after a reconnect HELO: send the STMd (and
    /// STMu) we held, or recover from the cut download.
    private func resolveHeldTrackEnd() {
        guard decodeEndHeld, !resolvingHeldTrackEnd else { return }
        resolvingHeldTrackEnd = true
        // Give a forgotten client's restart (LMS ignores the bit then) time to arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.decodeEndHeld else { return }
            if self.lifeboatUsed {
                // We played later tracks from copies: LMS has to come to us.
                self.clearHeldTrackEnd()
                self.jumpLMSToLifeboatPosition()
                return
            }
            if let held = self.decodeEndHeldAt, let started = self.lastServerStreamStartAt, started > held {
                os_log(.info, log: self.logger, "📬 LMS restarted the stream itself - dropping the held decode end")
                self.clearHeldTrackEnd()
                return
            }
            // Snapshot before asking: a gapless boundary crossed while the
            // reply is on its way would mix up which track the numbers are for.
            let stream = self.audioManager.pushStreamState()
            let trackTime = self.getCurrentInterpolatedTime().time
            let buffered = self.audioManager.bufferedPlaybackSeconds()
            let localIndex = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int
            let statusCommand: [String: Any] = [
                "id": 1, "method": "slim.request",
                "params": [self.settings.playerMACAddress, ["status", "-", 2, "tags:d"]]
            ]
            self.sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self, self.decodeEndHeld else { return }
                    guard let result = response["result"] as? [String: Any] else {
                        if self.connectionIsLive {
                            // SlimProto is fine but JSON-RPC isn't: don't stall the queue on it.
                            os_log(.info, log: self.logger, "📬 No status for the held decode end, connection live - sending STMd")
                            self.sendHeldTrackEnd()
                        } else {
                            // Unreachable after all: keep it held for the reconnect (or the next server frame).
                            os_log(.info, log: self.logger, "📬 No status for the held decode end - still holding")
                            self.resolvingHeldTrackEnd = false
                        }
                        return
                    }
                    let loop = result["playlist_loop"] as? [[String: Any]] ?? []
                    func duration(_ i: Int) -> Double {
                        guard i < loop.count else { return 0 }
                        return (loop[i]["duration"] as? Double) ?? Double("\(loop[i]["duration"] ?? "")") ?? 0
                    }
                    if let local = localIndex, let server = Self.playlistIndex(fromStatus: result), local != server {
                        // LMS isn't on the track we're playing: its durations don't apply.
                        os_log(.info, log: self.logger, "📬 Held decode end: LMS is on track %d, we're on %d - recovering", server, local)
                        self.recoverFromCutDownload()
                        return
                    }
                    let ended = Self.heldDecodeEndWasTrackEnd(
                        decodingAhead: stream.decodingAhead, decodedEndSeconds: stream.decodedEndSeconds,
                        trackTime: trackTime, bufferedSeconds: buffered,
                        currentDuration: duration(0), nextDuration: duration(1))
                    os_log(.info, log: self.logger,
                           "📬 Held decode end: %{public}s (ahead %{public}s, decoded %.1f, track time %.1f + buffered %.1f, durations %.1f / %.1f)",
                           ended ? "track ended - sending STMd" : "download was cut - recovering",
                           stream.decodingAhead ? "YES" : "NO", stream.decodedEndSeconds ?? -1,
                           trackTime, buffered, duration(0), duration(1))
                    if ended {
                        self.sendHeldTrackEnd()
                    } else {
                        self.recoverFromCutDownload()
                    }
                }
            }
        }
    }

    /// The held end was a real end: send STMd (and the STMu if it drained).
    private func sendHeldTrackEnd() {
        let drained = drainHeld
        clearHeldTrackEnd()
        sendTrackDecodeComplete(mayHold: false)
        if drained {
            sendPlaybackComplete()
        } else if audioManager.getPlayerState() == "Playing" {
            // The tail still plays and the next track follows gaplessly:
            // nothing will "start playback" to end the hold.
            endOutageHold(reason: "reconnected - track ended normally")
        }
    }

    private func recoverFromCutDownload(tryCopy: Bool = true) {
        if tryCopy, let index = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int {
            let stream = audioManager.pushStreamState()
            if continueFromCopy(index: stream.decodingAhead ? index + 1 : index, stream: stream) { return }
        }
        clearHeldTrackEnd()
        if outageHoldActive || audioManager.getPlayerState() == "Playing" {
            unlessPausedOnServer {
                self.performPlaylistRecovery(shouldPlay: true)
            }
        } else {
            performPlaylistRecovery(shouldPlay: false)
        }
    }

    private func clearHeldTrackEnd() {
        decodeEndHeldAt = nil
        decodeEndHeld = false
        drainHeld = false
        resolvingHeldTrackEnd = false
    }

    // MARK: - Lifeboat (ride out network loss, phase 2)

    /// Playing from copies (or paused offline) while the server is away.
    private var lifeboatHoldsSession: Bool {
        (lifeboatActive || lifeboatUsed) && !connectionIsLive
    }

    /// Copies may be played (whatever the network now: they were fetched earlier).
    /// Not in a sync group: our offline position would move every member (review M6).
    private var lifeboatEnabled: Bool { settings.lifeboatMode != 0 && settings.loadSyncGroupID() == nil }

    /// Copies may be downloaded now: always (2), or not on a metered network (1).
    private var lifeboatMayDownload: Bool {
        switch settings.lifeboatMode {
        case 2: return true
        case 1: return !connectionManager.networkIsExpensive
        default: return false
        }
    }

    /// Ask LMS for the queue ahead and keep the copies up to date.
    private func scheduleLifeboatPlan(after delay: TimeInterval) {
        guard settings.lifeboatMode != 0 else { return }
        startLifeboatWatch()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.lifeboatMayDownload, self.connectionIsLive, !self.lifeboatActive else { return }
            if let last = self.lifeboatPlanAt, Date().timeIntervalSince(last) < 1.5 { return }
            self.lifeboatPlanAt = Date()
            let command: [String: Any] = [
                "id": 1, "method": "slim.request",
                "params": [self.settings.playerMACAddress, ["status", "-", LifeboatCache.maxTracks + 1, "tags:acdlxuY"]]
            ]
            self.sendJSONRPCCommandDirect(command) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self = self, let result = response["result"] as? [String: Any] else { return }
                    let upcoming = Self.lifeboatTracks(fromStatus: result)
                    let elapsed = (result["time"] as? Double) ?? 0
                    self.lifeboat.update(upcoming: upcoming, elapsed: elapsed, streamFormat: self.currentStreamFormat,
                                         replayGainApplied: self.lastStreamReplayGain > 0,
                                         server: self.currentSessionServer,
                                         lookahead: TimeInterval(self.settings.lifeboatMinutes * 60),
                                         mayDownload: { [weak self] in self?.lifeboatMayDownload ?? false },
                                         allowExpensive: self.settings.lifeboatMode == 2)
                }
            }
        }
    }

    static func lifeboatTracks(fromStatus result: [String: Any]) -> [LifeboatCache.Track] {
        let loop = result["playlist_loop"] as? [[String: Any]] ?? []
        func number(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) ?? Double("\(v ?? "")") }
        return loop.compactMap { item in
            guard let index = number(item["playlist index"]).map({ Int($0) }),
                  let id = item["id"].map({ "\($0)" }) else { return nil }
            return LifeboatCache.Track(
                index: index, id: id,
                title: item["title"] as? String ?? "",
                artist: item["artist"] as? String ?? "",
                album: item["album"] as? String ?? "",
                duration: number(item["duration"]) ?? 0,
                // CUE-sheet tracks share one file (url "...#start-end"): a download is the whole album.
                remote: (number(item["remote"]) ?? 0) != 0 || ((item["url"] as? String)?.contains("#") ?? false),
                replayGainDB: number(item["replay_gain"]),
                coverID: item["coverid"].map { "\($0)" })
        }
    }

    /// Once a second: a network stream that stopped delivering while we
    /// can't reach the server (dead spot, connection still open) is given up
    /// before the buffer runs dry, so the downloaded copy takes over in time.
    private func startLifeboatWatch() {
        guard lifeboatWatchTimer == nil else { return }
        lifeboatWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.lifeboatEnabled, !self.lifeboatActive, !self.connectionIsLive,
                  self.audioManager.getPlayerState() == "Playing" || self.audioManager.isPushStreamStalled() else { return }
            let stream = self.audioManager.pushStreamState()
            guard stream.connected, !stream.completedNaturally,
                  self.audioManager.bufferedPlaybackSeconds() < Self.lifeboatSwitchMargin,
                  let index = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int,
                  self.lifeboat.fileURL(forIndex: stream.decodingAhead ? index + 1 : index) != nil else { return }
            self.audioManager.abandonNetworkStream()
        }
    }

    /// Buffered audio left when a stalled stream is given up for its copy:
    /// room to open the file and find the switch point.
    static let lifeboatSwitchMargin: TimeInterval = 8

    /// The decode ended because its download closed: the end of the track,
    /// or a cut (dead spot, Wi-Fi → cellular). The connection can't tell us
    /// which (it can still look live for 10s after the network died), so the
    /// track's duration does: from the downloaded-copies plan when we have
    /// it, else from LMS. True = handled here, don't send STMd now.
    private func handleDownloadEnd() -> Bool {
        let live = connectionIsLive
        let stream = audioManager.pushStreamState()
        guard let index = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int else {
            return live ? false : holdDownloadEnd(askNow: false)
        }
        let decodingIndex = stream.decodingAhead ? index + 1 : index

        if lifeboatUsed && lifeboatActive {
            // A copy ended; LMS doesn't know where we are: keep going with the copies.
            // (LMS's own stream played on after an offline Play is cut or ended below.)
            if startLifeboatTrack(index: decodingIndex + 1) { return true }
            return holdDownloadEnd(askNow: false)  // the reconnect moves LMS to us
        }
        if lifeboatActive {
            // The copy of LMS's own track ended: a real end of the track.
            if live {
                lifeboatActive = false
                return false  // STMd: LMS carries on as usual
            }
            if startLifeboatTrack(index: decodingIndex + 1) { return true }
            return holdDownloadEnd(askNow: false)
        }

        // A silent recovery flushing the old stream to replace it isn't a cut.
        if lifeboatEnabled, !audioManager.isSilentRecoveryMuted,
           let duration = lifeboat.track(at: decodingIndex)?.duration, duration > 0 {
            let ended = Self.heldDecodeEndWasTrackEnd(
                decodingAhead: stream.decodingAhead, decodedEndSeconds: stream.decodedEndSeconds,
                trackTime: getCurrentInterpolatedTime().time, bufferedSeconds: audioManager.bufferedPlaybackSeconds(),
                currentDuration: duration, nextDuration: duration)
            if ended {
                if live { return false }  // normal end of track: STMd now
                if startLifeboatTrack(index: decodingIndex + 1) { return true }
            } else {
                if continueFromCopy(index: decodingIndex, stream: stream) { return true }
                if live {
                    // Cut while still connected (Wi-Fi → cellular) and no copy: jump to where we are.
                    os_log(.info, log: logger, "📬 Download cut while connected - recovering at our position")
                    decodeEndHeld = true
                    recoverFromCutDownload(tryCopy: false)
                    return true
                }
            }
        }
        // Online with nothing to compare against: a normal end, as before.
        return live ? false : holdDownloadEnd(askNow: false)
    }

    /// Hold the STMd; with `askNow`, have LMS's durations settle it now.
    private func holdDownloadEnd(askNow: Bool) -> Bool {
        decodeEndHeld = true
        decodeEndHeldAt = Date()
        os_log(.info, log: logger, "📬 Download ended - holding STMd until we know the track ended (%{public}s)",
               askNow ? "asking LMS" : "server unreachable")
        if askNow { resolveHeldTrackEnd() }
        return true
    }

    /// Continue the cut track at playlist `index` from its downloaded copy.
    private func continueFromCopy(index: Int, stream: AudioStreamDecoder.StreamState) -> Bool {
        guard lifeboatEnabled, let file = lifeboat.fileURL(forIndex: index),
              let trackID = lifeboat.track(at: index)?.id, !unusableCopies.contains(trackID) else { return false }
        let estimate = stream.decodingAhead
            ? (stream.decodedEndSeconds ?? 0)
            : getCurrentInterpolatedTime().time + audioManager.bufferedPlaybackSeconds()
        os_log(.info, log: logger, "🛟 Download cut in track %d near %.1fs - continuing from the downloaded copy", index, estimate)
        clearHeldTrackEnd()
        lifeboatActive = true
        audioManager.continueFromLocalFile(path: file.path, estimatedSeconds: estimate,
                                           adjustTrackOffset: !stream.decodingAhead) { [weak self] result in
            guard let self = self else { return }
            guard let result = result else {
                // Don't try this copy again; recover the old way.
                self.unusableCopies.insert(trackID)
                self.lifeboatActive = false
                if self.connectionIsLive {
                    self.decodeEndHeld = true
                    self.recoverFromCutDownload(tryCopy: false)
                } else {
                    _ = self.holdDownloadEnd(askNow: false)
                }
                return
            }
            if !stream.decodingAhead {
                // The match says exactly where the playhead is in the track.
                let playhead = result.fileSeconds - self.audioManager.bufferedPlaybackSeconds()
                self.simpleTimeTracker.updateFromServer(time: playhead, playing: true)
            }
        }
        return true
    }

    /// Queue the downloaded copy of the track at `index` behind what's playing.
    private func startLifeboatTrack(index: Int) -> Bool {
        guard let file = lifeboat.fileURL(forIndex: index) else {
            os_log(.info, log: logger, "🛟 No downloaded copy of track %d - waiting for the server", index)
            return false
        }
        let gain = lifeboatGain(index: index)
        os_log(.info, log: logger, "🛟 Offline: queuing the downloaded copy of track %d (gain %.3f)", index, gain)
        lifeboatActive = true
        lifeboatUsed = true
        connectionManager.persistForPlayback = true
        audioManager.startPushStreamPlayback(url: file.absoluteString, format: currentStreamFormat,
                                             replayGain: gain, isGapless: true, startTime: 0, waitForUnpause: false)
        return true
    }

    /// Linear gain for the copy at `index`: LMS sends each track's gain in its
    /// strm; offline, use the track's ReplayGain tag when LMS applies gain for us.
    private func lifeboatGain(index: Int) -> Float {
        guard lastStreamReplayGain > 0, let db = lifeboat.track(at: index)?.replayGainDB else { return 0 }
        return Float(pow(10, db / 20))
    }

    /// What the settings screen shows while we play downloaded copies offline.
    struct OfflinePlaybackStatus: Equatable {
        let title: String
        let artist: String
        let isPaused: Bool
        /// Saved music left from the playhead, counting only the copies that follow on unbroken.
        let minutesLeft: Int
    }

    /// Non-nil while the server can't be reached and a downloaded copy is
    /// playing (or paused on the phone). Polled by the settings screen.
    var offlinePlaybackStatus: OfflinePlaybackStatus? {
        // From the moment iOS reports no network, not only once a copy takes over.
        guard lifeboatEnabled, lifeboat.server == currentSessionServer, !connectionIsLive,
              lifeboatActive || lifeboatPausedLocally || (networkUnavailable && audioManager.getPlayerState() == "Playing"),
              let index = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int,
              let track = lifeboat.track(at: index) else { return nil }
        var seconds = Self.offlineSecondsLeft(from: index, elapsed: getCurrentInterpolatedTime().time,
                                              duration: { self.lifeboat.track(at: $0)?.duration },
                                              hasCopy: { self.lifeboat.fileURL(forIndex: $0) != nil })
        if !lifeboatActive && lifeboat.fileURL(forIndex: index) == nil {
            // LMS's stream with no copy to take over: only the buffer is left (review L9).
            seconds = audioManager.bufferedPlaybackSeconds()
        }
        return OfflinePlaybackStatus(title: track.title, artist: track.artist,
                                     isPaused: lifeboatPausedLocally || audioManager.getPlayerState() == "Paused",
                                     minutesLeft: Int((seconds / 60).rounded(.down)))
    }

    /// What the offline player (over Material) shows: Material is a page from
    /// LMS and freezes on its last state while LMS can't be reached.
    struct OfflinePlayerState: Equatable {
        struct Item: Equatable, Identifiable {
            let index: Int
            let title: String
            let artist: String
            let duration: Double
            var id: Int { index }
        }
        let current: Item
        let album: String
        let artworkPath: String?
        let elapsed: Double
        let isPlaying: Bool
        let minutesLeft: Int
        /// The saved songs after this one, in queue order, while they follow on unbroken.
        let upNext: [Item]
    }

    var offlinePlayerState: OfflinePlayerState? {
        let playing = offlinePlaybackStatus
        let offer = playing == nil ? savedMusicOffer : nil
        guard playing != nil || offer != nil,
              let index = playing != nil ? UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int : offer?.index,
              let track = lifeboat.track(at: index) else { return nil }
        func item(_ t: LifeboatCache.Track) -> OfflinePlayerState.Item {
            OfflinePlayerState.Item(index: t.index, title: t.title, artist: t.artist, duration: t.duration)
        }
        var upNext: [OfflinePlayerState.Item] = []
        var next = index + 1
        while let t = lifeboat.track(at: next), lifeboat.fileURL(forIndex: next) != nil {
            upNext.append(item(t))
            next += 1
        }
        return OfflinePlayerState(
            current: item(track), album: track.album,
            artworkPath: lifeboat.artworkURL(forIndex: index)?.path,
            elapsed: playing != nil ? getCurrentInterpolatedTime().time : (offer?.position ?? 0),
            isPlaying: playing.map { !$0.isPaused } ?? false,
            minutesLeft: playing?.minutesLeft ?? offer?.minutesLeft ?? 0,
            upNext: upNext)
    }

    /// The offline player's buttons: the same handling as the lock screen's.
    func offlinePlayerCommand(_ command: String) {
        if offlinePlaybackStatus == nil, let offer = savedMusicOffer {
            // Nothing playing yet (launched offline): start the saved music.
            switch command {
            case "play": playSavedMusicOffline()
            case "next": playSavedTrackOffline(index: offer.index + 1)
            case "previous": playSavedTrackOffline(index: offer.index)
            default: break
            }
            return
        }
        _ = handleOfflineCommand(command)
    }

    /// Settings → Keep Playing Offline → Off: drop the copies (and the live plan).
    func clearSavedMusic() {
        lifeboat.removeAll()
    }

    /// Tap on a saved song in the offline player: play it from the start.
    func playSavedTrackOffline(index: Int) {
        guard !connectionIsLive, lifeboat.fileURL(forIndex: index) != nil else { return }
        os_log(.info, log: logger, "📴 Offline: playing the downloaded copy of track %d (chosen in the app)", index)
        prepareToPlaySavedMusic()
        _ = playLifeboatTrackNow(index: index)
    }

    /// Rest of track `index`, plus each following track while its copy is downloaded.
    static func offlineSecondsLeft(from index: Int, elapsed: Double,
                                   duration: (Int) -> Double?, hasCopy: (Int) -> Bool) -> Double {
        var total = max(0, (duration(index) ?? 0) - elapsed)
        var next = index + 1
        while hasCopy(next), let length = duration(next) {
            total += length
            next += 1
        }
        return total
    }

    /// Lock screen / CarPlay / AirPods buttons while we can't reach the
    /// server: act on the phone (LMS would never get them), and have the
    /// reconnect move LMS to what we ended up doing. True = handled.
    private func handleOfflineCommand(_ command: String) -> Bool {
        // Only during an outage. A suspended app's connection is dead too, and
        // there the normal path reconnects and tells LMS (device log 2026-10-19:
        // Play after a long background played the old buffer, LMS stayed paused).
        // Playing means not suspended: a silent connection then is an outage.
        // No network at all (airplane mode) is one too, paused or not.
        // Not lifeboatUsed alone: after the copies ran out a suspended app with the
        // network fine must reconnect and tell LMS (review H6).
        guard networkUnavailable || (!connectionIsLive &&
              (outageHoldActive || lifeboatPausedLocally || audioManager.getPlayerState() == "Playing")) else { return false }
        let state = audioManager.getPlayerState()
        let hasLocalAudio = state == "Playing" || state == "Paused" || audioManager.isPushStreamStalled() || lifeboatActive
        guard hasLocalAudio, let index = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int else {
            return false
        }
        switch command {
        case "pause", "stop":
            audioManager.pause()
            lifeboatPausedLocally = true
            lifeboatUsed = true
            connectionManager.persistForPlayback = true
            let position = getCurrentTimeForSaving()
            simpleTimeTracker.updateFromServer(time: position, playing: false)
            UserDefaults.standard.set(position, forKey: "lyrplay_recovery_position")
            UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
            endOutageHold(reason: "paused offline")
            os_log(.info, log: logger, "📴 Offline: paused on the phone at %.1fs", position)
            return true
        case "play":
            guard state == "Paused" || lifeboatPausedLocally else { return true }
            lifeboatPausedLocally = false
            // LMS never hears this Play: the reconnect moves it to us, over its older pause.
            lifeboatUsed = true
            savedMusicStartedOffline = true
            connectionManager.persistForPlayback = true
            beginOutageHold(reason: "playing offline")
        // Earlier attempts may have given up while nothing played (launched offline).
        connectionManager.resumeReconnecting(reason: "playing offline")
            audioManager.play()
            simpleTimeTracker.updateFromServer(time: getCurrentTimeForSaving(), playing: true)
            os_log(.info, log: logger, "📴 Offline: resumed on the phone")
            return true
        case "next":
            if playLifeboatTrackNow(index: index + 1) {
                os_log(.info, log: logger, "📴 Offline: skipped to the downloaded copy of track %d", index + 1)
            } else {
                os_log(.info, log: logger, "📴 Offline: no downloaded copy of track %d - staying", index + 1)
            }
            return true
        case "previous":
            // Back to the start of this song (earlier copies are already deleted).
            if !playLifeboatTrackNow(index: index) {
                os_log(.info, log: logger, "📴 Offline: no downloaded copy of track %d to restart", index)
            }
            return true
        default:
            return false
        }
    }

    /// Copies played or buttons handled offline: LMS doesn't know where we are.
    var offlinePlaybackOwnsRecovery: Bool { lifeboatUsed || lifeboatPausedLocally }

    /// No network at all (airplane mode, no signal), as iOS reports it.
    private var networkUnavailable: Bool { connectionManager.networkStatus == .unavailable }
    private var serverUnreachable: Bool {
        networkUnavailable || (serverUnreachableSince.map { Date().timeIntervalSince($0) > 8 } ?? false)
    }

    /// Saved music the app can play with no server (e.g. launched in a dead spot).
    struct SavedMusicOffer: Equatable {
        let index: Int
        let position: Double
        let title: String
        let minutesLeft: Int
    }

    /// Non-nil when the server can't be reached, nothing is playing, and the
    /// track we were last on has a downloaded copy.
    var savedMusicOffer: SavedMusicOffer? {
        let state = audioManager.getPlayerState()
        guard lifeboatEnabled, !connectionIsLive, !lifeboatActive, !lifeboatPausedLocally,
              (serverUnreachable && (state == "No Stream" || state == "Stopped")) || (state == "Paused" && networkUnavailable),
              var index = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int,
              lifeboat.server == currentSessionServer,  // copies from this server (review H7)
              let saved = lifeboat.track(at: index) else { return nil }
        var position = state == "Paused" ? getCurrentTimeForSaving()
            : max(0, UserDefaults.standard.double(forKey: "lyrplay_recovery_position"))
        if position > saved.duration - 2 {
            // Saved at the very end: the next track is where playback goes on.
            index += 1
            position = 0
        }
        guard let track = lifeboat.track(at: index), lifeboat.fileURL(forIndex: index) != nil else { return nil }
        let seconds = Self.offlineSecondsLeft(from: index, elapsed: position,
                                              duration: { self.lifeboat.track(at: $0)?.duration },
                                              hasCopy: { self.lifeboat.fileURL(forIndex: $0) != nil })
        guard seconds >= 30 else { return nil }
        return SavedMusicOffer(index: index, position: position, title: track.title,
                               minutesLeft: Int((seconds / 60).rounded(.down)))
    }

    /// Play the saved copies from where we left off; the reconnect then moves LMS here.
    func playSavedMusicOffline() {
        guard let offer = savedMusicOffer else { return }
        if audioManager.getPlayerState() == "Paused" {
            // Paused when the network went: play on from the buffer (then the copy).
            _ = handleOfflineCommand("play")
            return
        }
        os_log(.info, log: logger, "📴 Offline: playing saved music from track %d at %.1fs", offer.index, offer.position)
        prepareToPlaySavedMusic()
        _ = playLifeboatTrackNow(index: offer.index, from: offer.position)
    }

    /// Before starting a copy the user chose with no server.
    private func prepareToPlaySavedMusic() {
        offlinePlayerRequested = true
        // This IS the recovery: the app-open jump would start LMS's stream over it.
        pendingRecoveryTrigger = .none
        audioManager.cancelPreMute(reason: "playing saved music")
        // A fresh launch hasn't had a stream from LMS: use what the copies were made for.
        if currentStreamFormat.isEmpty { currentStreamFormat = lifeboat.streamFormat }
        // The copies continue the last session on this server: reconnect to it
        // (with the HELO reconnect bit) so LMS doesn't restart its own stream
        // over ours, and the reconnect moves LMS here.
        if sessionServer == nil { sessionServer = currentSessionServer }
        savedMusicStartedOffline = true
        if lastStreamReplayGain == 0 && lifeboat.replayGainApplied {
            lastStreamReplayGain = 1  // only "LMS applies gain" matters to lifeboatGain
        }
    }

    /// Start the copy of track `index` now, from `position` (a skip starts at 0).
    private func playLifeboatTrackNow(index: Int, from position: Double = 0) -> Bool {
        guard let file = lifeboat.fileURL(forIndex: index), let track = lifeboat.track(at: index) else { return false }
        clearHeldTrackEnd()
        lifeboatActive = true
        lifeboatUsed = true
        savedMusicStartedOffline = true  // a skip or a chosen song: newer than LMS's state (review M3)
        connectionManager.persistForPlayback = true
        lifeboatPausedLocally = false
        UserDefaults.standard.set(index, forKey: "lyrplay_recovery_index")
        UserDefaults.standard.set(position, forKey: "lyrplay_recovery_position")
        UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
        beginOutageHold(reason: "playing offline")
        // Earlier attempts may have given up while nothing played (launched offline).
        connectionManager.resumeReconnecting(reason: "playing offline")
        audioManager.startPushStreamPlayback(url: file.absoluteString, format: currentStreamFormat,
                                             replayGain: lifeboatGain(index: index), isGapless: false,
                                             startTime: position, waitForUnpause: false)
        simpleTimeTracker.updateFromServer(time: position, duration: track.duration, playing: true)
        audioManager.updateTrackMetadata(title: track.title, artist: track.artist, album: track.album,
                                         artworkURL: nil, duration: track.duration)
        return true
    }

    /// Back online after playing copies: put LMS where we are (one jump per
    /// connection). Play or pause comes from what the phone is doing now, not
    /// from what a caller saw at the disconnect (review 2026-10-19, H1).
    private func jumpLMSToLifeboatPosition() {
        guard let connected = lastConnectedAt, lifeboatJumpConnection != connected else { return }
        // The copies came from one server: on another (backup failover, a server
        // switch) their ids and indexes mean nothing there.
        guard lifeboat.server == currentSessionServer else {
            os_log(.info, log: logger, "🛟 Connected to another server than the downloaded copies came from - following it")
            abandonLifeboat(stopLocal: true)
            return
        }
        lifeboatJumpConnection = connected
        // The strm q/s our jump causes is not LMS restarting a forgotten player:
        // without this it was muted for the 8s ceiling (device log 2026-10-19 05:13:47).
        reconnectTarget = nil
        let shouldPlay = !lifeboatPausedLocally && audioManager.getPlayerState() != "Paused"
        let userActedOffline = savedMusicStartedOffline
        let position = getCurrentTimeForSaving()
        let index = UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int
        let playedID = index.flatMap { lifeboat.track(at: $0)?.id }
        // The queue may have changed while we were away: find the track we
        // played by its id, near the index we think it has.
        let lookup: [String: Any] = [
            "id": 1, "method": "slim.request",
            "params": [settings.playerMACAddress, ["status", 0, 500, "tags:"]]
        ]
        sendJSONRPCCommandDirect(lookup) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self, self.lifeboatUsed || self.lifeboatPausedLocally else { return }
                let result = response["result"] as? [String: Any]
                var target = index
                if let playedID = playedID, let index = index,
                   let loop = result?["playlist_loop"] as? [[String: Any]] {
                    let found = loop.compactMap { item -> Int? in
                        guard "\(item["id"] ?? "")" == playedID else { return nil }
                        return Self.playlistIndex(fromStatus: ["playlist_cur_index": item["playlist index"] as Any])
                    }
                    guard let nearest = found.min(by: { abs($0 - index) < abs($1 - index) }) else {
                        // Not in LMS's queue any more (replaced or edited elsewhere):
                        // an index into the new queue would be an unrelated song.
                        os_log(.info, log: self.logger, "🛟 The track we played is no longer in LMS's queue - following the server")
                        self.abandonLifeboat(stopLocal: true)
                        return
                    }
                    target = nearest
                }
                if let target = target, target != index {
                    os_log(.info, log: self.logger, "🛟 The track we played moved in the queue: %d → %d", index ?? -1, target)
                    UserDefaults.standard.set(target, forKey: "lyrplay_recovery_index")
                }
                os_log(.info, log: self.logger, "🛟 Back online after playing downloaded copies - moving LMS to track %{public}s at %.1fs (%{public}s)",
                       target.map(String.init) ?? "?", position, shouldPlay ? "playing" : "paused")
                UserDefaults.standard.set(position, forKey: "lyrplay_recovery_position")
                UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
                self.audibleRecoveryTarget = nil
                self.savedMusicStartedOffline = false
                if !shouldPlay {
                    self.forcePausedRestore = true
                    self.performPlaylistRecovery(shouldPlay: false)
                } else if !userActedOffline, result?["mode"] as? String == "pause" {
                    // Nobody touched the phone offline, and LMS is paused: someone
                    // paused it elsewhere during the outage. That wins.
                    os_log(.info, log: self.logger, "🛟 Paused on the server during the outage - pausing here too")
                    self.audioManager.pause()
                    self.abandonLifeboat(stopLocal: false)
                } else {
                    // A play pressed offline is newer than LMS's pause.
                    self.performPlaylistRecovery(shouldPlay: true)
                }
            }
        }
    }

    /// Give up on the copies and follow the server as it is.
    private func abandonLifeboat(stopLocal: Bool) {
        if stopLocal && (lifeboatActive || lifeboatUsed) { audioManager.stop() }
        clearHeldTrackEnd()
        lifeboatActive = false
        lifeboatUsed = false
        lifeboatPausedLocally = false
        savedMusicStartedOffline = false
        forcePausedRestore = false
        reconnectTarget = nil
        endOutageHold(reason: "following the server")
        connectionManager.persistForPlayback = false
    }

    // MARK: - Outage Hold (bd 6lvg, 8tjj)

    /// Start the outage hold. No-op if already on: the time limit counts from
    /// the start of the outage, so repeated drops can't extend it. Main thread only.
    private func beginOutageHold(reason: String) {
        guard !outageHoldActive else { return }
        outageHoldGeneration += 1
        let generation = outageHoldGeneration
        outageHoldActive = true
        audibleRecoveryRetries = 0
        audioManager.setOutputKeepAlive(true)
        connectionManager.persistForPlayback = true
        os_log(.info, log: logger, "🔋 Outage hold ON (%{public}s)", reason)
        scheduleOutageHoldLimit(generation: generation)
        scheduleOutageHoldWatchdog(generation: generation)
        scheduleOutageHoldClock(generation: generation)
    }

    /// The hold ends after `outageHoldLimit`, unless a downloaded copy is
    /// playing: then the outage can last as long as the copies do, and we
    /// keep reconnecting.
    private func scheduleOutageHoldLimit(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.outageHoldLimit) { [weak self] in
            guard let self = self, self.outageHoldGeneration == generation else { return }
            if self.lifeboatActive && self.audioManager.getPlayerState() == "Playing" {
                os_log(.info, log: self.logger, "🛟 Outage hold limit reached while playing downloaded copies - keeping it")
                self.scheduleOutageHoldLimit(generation: generation)
                return
            }
            self.endOutageHold(reason: "time limit")
        }
    }

    /// Every 1s while the hold is on: once local audio stops flowing (buffer
    /// ran dry, stream stopped or failed), stop the time tracker. Otherwise it
    /// keeps interpolating as "playing" and NowPlayingManager keeps saving that
    /// advancing time as the recovery position, so recovery would land minutes
    /// ahead of what the user last heard.
    private func scheduleOutageHoldClock(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.outageHoldActive, self.outageHoldGeneration == generation else { return }
            let (time, playing) = self.simpleTimeTracker.getCurrentTime()
            if playing && self.audioManager.getPlayerState() != "Playing" {
                self.simpleTimeTracker.updateFromServer(time: time, playing: false)
                os_log(.info, log: self.logger, "🔋 Outage hold: audio not flowing - holding position at %.2f", time)
            }
            self.scheduleOutageHoldClock(generation: generation)
        }
    }

    /// Every 30s while the hold is on: connected but still no audio → retry.
    /// (Disconnected drops are handled by the reconnect → .networkRestored path.)
    private func scheduleOutageHoldWatchdog(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self = self, self.outageHoldActive, self.outageHoldGeneration == generation else { return }
            if self.audioManager.getPlayerState() == "Playing" && self.serverHeardRecently {
                // Audio is flowing on a live connection: nothing left to recover.
                self.endOutageHold(reason: "playing on a live connection")
                return
            }
            if self.connectionManager.connectionState.isConnected,
               !self.isRecoveryInProgress,
               !self.serverStartedStreamRecently {
                self.retryAudibleRecovery(reason: "still no playback")
            }
            self.scheduleOutageHoldWatchdog(generation: generation)
        }
    }

    /// A server stream start in the last 15s means a restart may still be
    /// opening; a recovery jump now would collide with it.
    private var serverStartedStreamRecently: Bool {
        guard let started = lastServerStreamStartAt else { return false }
        return Date().timeIntervalSince(started) < 15
    }

    /// End the outage hold. Main thread only; no-op when not active.
    private func endOutageHold(reason: String) {
        guard outageHoldActive else { return }
        outageHoldActive = false
        outageHoldGeneration += 1  // cancels the pending time limit
        audibleRecoveryTarget = nil
        holdTimeUntilRecoveryJump = false
        audioManager.setOutputKeepAlive(false)
        // Out of step with LMS (copies or offline buttons): keep reconnecting
        // until we can move it to where we are.
        connectionManager.persistForPlayback = lifeboatUsed
        // Nothing left to resume: a later reconnect must not start playback
        // on its own (wasPlaying is recomputed at the next disconnect).
        wasPlayingBeforeDisconnect = false
        if case .networkRestored = pendingRecoveryTrigger {
            pendingRecoveryTrigger = .none
        }
        os_log(.info, log: logger, "🔋 Outage hold OFF (%{public}s)", reason)
    }

    /// Automatic recoveries (reconnect, retries) must not override a pause
    /// made elsewhere (Material, another controller) while we were away. Runs
    /// `action` unless LMS says the player is paused; then ends the hold.
    /// Proceeds if the status query fails (the jump would fail too, and retry).
    private func unlessPausedOnServer(_ action: @escaping () -> Void) {
        unlessPausedOnServer(withStatus: { _ in action() })
    }

    /// Same, passing LMS's status result (nil if the query failed) to `action`.
    private func unlessPausedOnServer(withStatus action: @escaping ([String: Any]?) -> Void) {
        let statusCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["status", "-", 1]]
        ]
        sendJSONRPCCommandDirect(statusCommand) { [weak self] response in
            DispatchQueue.main.async {
                guard let self = self, self.outageHoldActive else { return }
                let result = response["result"] as? [String: Any]
                let mode = result?["mode"] as? String
                if mode == "pause" {
                    self.endOutageHold(reason: "paused on server")
                    return
                }
                action(result)
            }
        }
    }

    /// PlaybackSessionController: an audio interruption began (bd 6lvg). A
    /// call or another app taking the audio ends any attempt to resume (we'd
    /// otherwise jump-and-play into it); a quick Siri request doesn't.
    func outageHoldInterruptionBegan(isSiri: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !isSiri else { return }
            self.endOutageHold(reason: "audio interruption")
        }
    }

    /// An audible recovery didn't get playback going. Retry while the hold is
    /// on: now if we're connected, otherwise on the next reconnect.
    private func retryAudibleRecovery(reason: String) {
        guard outageHoldActive else { return }
        guard connectionManager.connectionState.isConnected else {
            pendingRecoveryTrigger = .networkRestored
            os_log(.info, log: logger, "🔁 Audible recovery %{public}s - will retry on reconnect", reason)
            return
        }
        guard audibleRecoveryRetries < Self.maxAudibleRecoveryRetries else {
            // Connected and nothing left to try: don't keep the app awake
            // playing silence for the rest of the time limit.
            os_log(.error, log: logger, "🔁 Audible recovery %{public}s - out of retries", reason)
            endOutageHold(reason: "out of retries")
            return
        }
        audibleRecoveryRetries += 1
        os_log(.info, log: logger, "🔁 Audible recovery %{public}s - retry %d/%d in 5s",
               reason, audibleRecoveryRetries, Self.maxAudibleRecoveryRetries)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, self.outageHoldActive else { return }
            // A timed-out jump may still have reached the server and started a
            // stream; don't jump on top of it (the watchdog re-checks later).
            guard !self.serverStartedStreamRecently else {
                os_log(.info, log: self.logger, "🔁 Skipping retry - server started a stream recently")
                return
            }
            self.unlessPausedOnServer {
                self.performPlaylistRecovery(shouldPlay: true)
            }
        }
    }

    // MARK: - Media Services Reset (bd 27ye)

    private func currentMediaServicesSnapshot() -> MediaServicesSnapshot {
        let state = audioManager.getPlayerState()
        return MediaServicesSnapshot(
            audioPlaying: state == "Playing" || state == "Buffering" || audioManager.isPushStreamStalled(),
            outageHoldActive: outageHoldActive,
            audibleRecoveryInProgress: isRecoveryInProgress && !currentRecoveryIsSilent,
            silentRecoveryInProgress: audioManager.isSilentRecoveryMuted,
            startDroppedWhileSuspended: audioManager.startDroppedWhileSuspended)
    }

    /// AVAudioSession media services were lost: the app has no audio session
    /// until iOS posts the reset. Note what we were doing and stop using BASS
    /// output until then.
    func mediaServicesWereLost() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.mediaServicesLostSinceReinit = true
            let (time, playing) = self.simpleTimeTracker.getCurrentTime()
            if self.mediaServicesLossSnapshot == nil {
                self.mediaServicesLossSnapshot = self.currentMediaServicesSnapshot()
                self.mediaServicesLossPosition = time
            }
            os_log(.error, log: self.logger, "🔄 Media services lost (wants playback: %{public}s, at %.2f seconds)",
                   self.mediaServicesLossSnapshot?.wantsPlayback == true ? "YES" : "NO",
                   self.mediaServicesLossPosition ?? time)
            // No audio flows until the reset; stop the clock so the saved
            // recovery position doesn't run ahead of what the user heard.
            if playing {
                self.simpleTimeTracker.updateFromServer(time: time, playing: false)
            }
            self.audioManager.suspendOutputForMediaServicesLoss()

            // iOS should follow with a reset. If it doesn't, try anyway rather
            // than leave the output suspended for good.
            self.mediaServicesGeneration += 1
            let generation = self.mediaServicesGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                guard let self = self, self.mediaServicesGeneration == generation else { return }
                os_log(.error, log: self.logger, "🔄 No media services reset 10s after loss - re-initializing anyway")
                self.recoverFromMediaServicesReset(trigger: .lossFallback)
            }
        }
    }

    /// AVAudioSession media services were reset. The new session has iOS's
    /// default category, which audiomxd refuses for background playback
    /// (error -16980, captured 2026-10-12). Re-init BASS so it sets the
    /// session up again, then resume if we were playing.
    func mediaServicesWereReset() {
        DispatchQueue.main.async { [weak self] in
            self?.recoverFromMediaServicesReset(trigger: .resetNotification)
        }
    }

    /// AudioManager: BASS re-init failed earlier and a start, play or
    /// foreground arrived; try again (lazily, not on a timer).
    func retryFailedOutputReinit() {
        DispatchQueue.main.async { [weak self] in
            self?.recoverFromMediaServicesReset(trigger: .lazyRetry)
        }
    }

    private enum MediaServicesReinitTrigger {
        case resetNotification, lossFallback, lazyRetry
    }

    private func recoverFromMediaServicesReset(trigger: MediaServicesReinitTrigger) {
        if trigger == .resetNotification,
           Self.isDuplicateReset(secondsSinceResetReinit: lastResetReinitAt.map { Date().timeIntervalSince($0) },
                                 lostSinceReinit: mediaServicesLostSinceReinit) {
            os_log(.info, log: logger, "🔄 Media services reset - duplicate of the one just handled, ignoring")
            return
        }
        mediaServicesGeneration += 1  // cancels the loss fallback
        guard !mediaServicesReinitInFlight else {
            os_log(.info, log: logger, "🔄 Media services reset - re-init already in progress")
            return
        }
        mediaServicesReinitInFlight = true
        let atLoss = mediaServicesLossSnapshot
        mediaServicesLossSnapshot = nil
        // Read before re-init frees the streams (covers a reset with no loss).
        let audioPlayingAtReset = currentMediaServicesSnapshot().audioPlaying
        let (time, playing) = simpleTimeTracker.getCurrentTime()
        if playing {
            simpleTimeTracker.updateFromServer(time: time, playing: false)
        }
        let resumePosition = mediaServicesLossPosition ?? time

        audioManager.reinitializeOutputAfterMediaServicesReset { [weak self] success in
            guard let self = self else { return }
            self.mediaServicesReinitInFlight = false
            guard success else {
                // No output device: nothing can play, so don't hold on to the
                // keep-alive and retries. AudioManager stays suspended and
                // retries on the next start, play or foreground.
                self.endOutageHold(reason: "audio re-init failed")
                return
            }
            self.mediaServicesLostSinceReinit = false
            self.mediaServicesLossPosition = nil
            self.lastResetReinitAt = trigger == .resetNotification ? Date() : nil
            var atReset = self.currentMediaServicesSnapshot()
            atReset.audioPlaying = audioPlayingAtReset
            let action = Self.mediaServicesResetAction(atLoss: atLoss, atReset: atReset)
            os_log(.error, log: self.logger, "🔄 Media services reset handled: BASS re-initialized, %{public}s",
                   action == .reinitializeAndResume ? "resuming via playlist jump" : "not resuming (paused or idle)")
            guard action == .reinitializeAndResume else { return }

            // The re-init freed any stream the server started for us, so the
            // "server started a stream recently" guard must not skip our jump.
            self.lastServerStreamStartAt = nil
            self.beginOutageHold(reason: "media services reset")
            self.unlessPausedOnServer(withStatus: { status in
                // Jump to the track LMS is on now. The saved index may be
                // gone: a jump that just succeeded deletes all three keys,
                // and the 3s poll that rewrites it is held off after a jump.
                // Without an index the recovery sends a plain play instead.
                if let index = Self.playlistIndex(fromStatus: status) {
                    self.setRecoveryIndexFromServer(index)
                }
                // Not the tracker: polls since the loss carry LMS's time
                // from our 0-elapsed STATs (device test 2026-10-12: 0.69s
                // instead of 2:09).
                let position = resumePosition
                if position > 0 {
                    // Seed the tracker too, so NowPlayingManager's periodic
                    // save doesn't write the poisoned time back.
                    self.simpleTimeTracker.updateFromServer(time: position, playing: false)
                    UserDefaults.standard.set(position, forKey: "lyrplay_recovery_position")
                    UserDefaults.standard.set(Date(), forKey: "lyrplay_recovery_timestamp")
                    os_log(.info, log: self.logger, "💾 Saved recovery state on media services reset: track %{public}s at %.2f seconds",
                           (UserDefaults.standard.object(forKey: "lyrplay_recovery_index") as? Int).map(String.init) ?? "unknown", position)
                }
                self.performPlaylistRecovery(shouldPlay: true)
            })
        }
    }

    func handleDecoderDidStartPlayback() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Audio from a downloaded copy while the server is away isn't the
            // server's playback coming back: keep the hold (and the reconnects).
            if self.lifeboatHoldsSession { return }
            self.endOutageHold(reason: "playback started")
            if let generation = self.silentRecoveryPauseGeneration {
                self.sendSilentRecoveryPause(generation: generation, reason: "silent stream playing")
            }
        }
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
