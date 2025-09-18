// File: SlimProtoCoordinator.swift
// Enhanced with SimpleTimeTracker for accurate lock screen timing
import Foundation
import os.log
import WebKit


class SlimProtoCoordinator: ObservableObject {
    
    // MARK: - Components
    private let client: SlimProtoClient
    private let commandHandler: SlimProtoCommandHandler
    private let connectionManager: SlimProtoConnectionManager
    private let audioManager: AudioManager
    private let simpleTimeTracker: SimpleTimeTracker // NEW: Material-style time tracking
    private weak var webView: WKWebView? // NEW: WebView for Material UI refresh
    
    // MARK: - Dependencies
    private let settings = SettingsManager.shared
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SlimProtoCoordinator")
    
    private var metadataRefreshTimer: Timer?
    
    // MARK: - Settings Tracking (ADD THESE LINES)
    private(set) var lastKnownHost: String = ""
    private(set) var lastKnownPort: UInt16 = 3483
    private var playbackHeartbeatTimer: Timer?
    
    // MARK: - Background State Tracking
    private var isAppInBackground: Bool = false
    private var backgroundedWhilePlaying: Bool = false
    private var wasDisconnectedWhileInBackground: Bool = false
    private var isSavingVolume = false
    private var isRestoringVolume = false
    
    // MARK: - Legacy Timer (for compatibility)
    private var serverTimeTimer: Timer?

    
    // MARK: - Initialization
    init(audioManager: AudioManager) {
        self.audioManager = audioManager
        self.client = SlimProtoClient()
        self.commandHandler = SlimProtoCommandHandler()
        self.connectionManager = SlimProtoConnectionManager()
        self.simpleTimeTracker = SimpleTimeTracker() // NEW: Initialize Material-style tracker
        
        setupDelegation()
        setupAudioCallbacks()
        setupAudioPlayerIntegration()

        os_log(.info, log: logger, "SlimProtoCoordinator initialized with Material-style time tracking")
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
        // Set up track ended callback
        audioManager.onTrackEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.commandHandler.notifyTrackEnded()
            }
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

    /// Request server-side seek for transcoding pipeline fixes
    func requestSeekToTime(_ timeOffset: Double) {
        os_log(.info, log: logger, "🔧 Requesting server seek to %{public}.2f seconds for transcoding fix", timeOffset)

        // Use proper JSON-RPC structure like existing recovery methods
        let seekCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["time", timeOffset]]
        ]

        sendJSONRPCCommandDirect(seekCommand) { [weak self] response in
            os_log(.info, log: self?.logger ?? OSLog.default, "🔧 Server seek command completed")
        }
    }
    
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
    
    private func startPlaybackHeartbeat() {
        stopPlaybackHeartbeat()
        
        // Only during active playback, send STMt every second like squeezelite
        playbackHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // Only send if actively playing (not paused/stopped)
            if self.audioManager.getPlayerState() == "playing" && !self.commandHandler.isPausedByLockScreen {
                self.client.sendStatus("STMt")
            }
        }
    }

    private func stopPlaybackHeartbeat() {
        playbackHeartbeatTimer?.invalidate()
        playbackHeartbeatTimer = nil
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
    
    private func startMetadataRefreshForRadio() {
        // Stop any existing timer
        stopMetadataRefresh()
        
        // For radio streams, refresh metadata every 15 seconds to catch track changes faster
        metadataRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            os_log(.debug, log: self?.logger ?? OSLog.default, "🔄 Timer triggered metadata refresh")
            self?.fetchCurrentTrackMetadata()
        }
        
        os_log(.debug, log: logger, "🎵 Started metadata refresh for radio stream")
    }

    private func stopMetadataRefresh() {
        metadataRefreshTimer?.invalidate()
        metadataRefreshTimer = nil
    }
    
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
        stopMetadataRefresh()  // Add this line
        // Use position-saving disconnect when app is being deallocated
        client.disconnectWithPositionSave()
    }
    
    // MARK: - Recovery State Management
    private var isRecoveryInProgress = false
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
    
    /// Perform playlist jump with timeOffset recovery (Home Assistant style)
    private func performPlaylistRecovery() {
        recoveryQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Check if recovery is already in progress
            guard !self.isRecoveryInProgress else {
                os_log(.info, log: self.logger, "🔒 Lock Screen Recovery: Skipping - recovery already in progress")
                return
            }
            
            // Set recovery in progress
            self.isRecoveryInProgress = true
            os_log(.info, log: self.logger, "🔒 Lock Screen Recovery: Starting (blocking other recovery methods)")
            
            DispatchQueue.main.async { [weak self] in
                self?.executeLockScreenRecovery()
            }
        }
    }
    
    private func executeLockScreenRecovery() {
        // Check if we have recovery data (no time limit - like other music players)
        guard UserDefaults.standard.object(forKey: "lyrplay_recovery_timestamp") != nil else {
            os_log(.info, log: logger, "🔄 No recovery data - using simple play command")
            sendJSONRPCCommand("play")
            isRecoveryInProgress = false // Clear recovery flag
            return
        }
        
        let savedIndex = UserDefaults.standard.integer(forKey: "lyrplay_recovery_index")
        let savedPosition = UserDefaults.standard.double(forKey: "lyrplay_recovery_position")
        
        guard savedPosition > 0 else {
            os_log(.info, log: logger, "🔄 No saved position - using simple play command") 
            sendJSONRPCCommand("play")
            isRecoveryInProgress = false // Clear recovery flag
            return
        }
        
        os_log(.info, log: logger, "🎯 Performing playlist recovery: jump to track %d at %.2f seconds", savedIndex, savedPosition)
        
        // Use Home Assistant approach: playlist jump with timeOffset
        let playlistJumpCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, [
                "playlist", "jump", savedIndex, 1, 0, [
                    "timeOffset": savedPosition
                ]
            ]]
        ]
        
        sendJSONRPCCommandDirect(playlistJumpCommand) { [weak self] response in
            os_log(.info, log: self?.logger ?? OSLog.default, "🎯 Playlist jump recovery completed")
            
            // Clear recovery flag after completion
            self?.isRecoveryInProgress = false
            os_log(.info, log: self?.logger ?? OSLog.default, "🔒 Recovery state cleared - other recovery methods can now proceed")
            
            // Clear recovery data after successful use
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_index")
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_position")
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_timestamp")
        }
    }
    
    /// CarPlay reconnect recovery - connects to server first, then performs playlist jump
    func performCarPlayRecovery() {
        // Check if recovery is already in progress
        guard !isRecoveryInProgress else {
            os_log(.info, log: logger, "🚗 CarPlay Recovery: Skipping - recovery already in progress")
            return
        }

        // Set recovery in progress
        isRecoveryInProgress = true
        os_log(.info, log: logger, "🚗 CarPlay Recovery: Starting (blocking other recovery methods)")

        // CRITICAL: Always activate audio session for CarPlay recovery (same as lock screen)
        audioManager.activateAudioSession()

        // CRITICAL: Check connection status first (same logic as lock screen recovery)
        if !connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "🚗 CarPlay disconnected from server - will perform playlist jump recovery")
            connect()

            // Queue recovery after connection
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.executeCarPlayPlaylistJump()
            }
        } else {
            os_log(.info, log: logger, "🚗 CarPlay connected to server - using simple play command")
            sendJSONRPCCommand("play")
            isRecoveryInProgress = false // Clear recovery flag
        }
    }

    /// Execute CarPlay playlist jump recovery (matches lock screen recovery logic)
    private func executeCarPlayPlaylistJump() {
        // Check if we have recovery data (no time limit - like other music players)
        guard UserDefaults.standard.object(forKey: "lyrplay_recovery_timestamp") != nil else {
            os_log(.info, log: logger, "🚗 No recovery data for CarPlay - using simple play command")
            sendJSONRPCCommand("play")
            isRecoveryInProgress = false // Clear recovery flag
            return
        }

        let savedIndex = UserDefaults.standard.integer(forKey: "lyrplay_recovery_index")
        let savedPosition = UserDefaults.standard.double(forKey: "lyrplay_recovery_position")

        guard savedPosition > 0 else {
            os_log(.info, log: logger, "🚗 No saved position for CarPlay - using simple play command")
            sendJSONRPCCommand("play")
            isRecoveryInProgress = false // Clear recovery flag
            return
        }

        os_log(.info, log: logger, "🚗 Performing CarPlay playlist recovery: jump to track %d at %.2f seconds", savedIndex, savedPosition)

        // Use same Home Assistant approach: playlist jump with timeOffset
        let playlistJumpCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, [
                "playlist", "jump", savedIndex, 1, 0, [
                    "timeOffset": savedPosition
                ]
            ]]
        ]

        sendJSONRPCCommandDirect(playlistJumpCommand) { [weak self] response in
            os_log(.info, log: self?.logger ?? OSLog.default, "🚗 CarPlay playlist jump recovery completed")

            // Clear recovery flag after completion
            self?.isRecoveryInProgress = false
            os_log(.info, log: self?.logger ?? OSLog.default, "🚗 Recovery state cleared - other recovery methods can now proceed")

            // Clear recovery data after successful use
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_index")
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_position")
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_timestamp")
        }
    }

    /// App open recovery - same playlist jump method but pauses after recovery
    func performAppOpenRecovery() {
        // 🚫 DISABLED: App open recovery temporarily disabled for testing
        os_log(.info, log: logger, "📱 App Open Recovery: DISABLED for testing")

        recoveryQueue.async { [weak self] in
            guard let self = self else { return }

            // Check if recovery is already in progress
            guard !self.isRecoveryInProgress else {
                os_log(.info, log: self.logger, "📱 App Open Recovery: Skipping - recovery already in progress")
                return
            }

            // Check if we were disconnected while in background - this indicates recovery is needed
            guard self.wasDisconnectedWhileInBackground else {
                os_log(.info, log: self.logger, "📱 App Open Recovery: Skipping - was not disconnected while in background")
                return
            }

            // Check if we have recovery data (no time limit - like other music players)
            guard UserDefaults.standard.object(forKey: "lyrplay_recovery_timestamp") != nil else {
                os_log(.info, log: self.logger, "📱 No recovery data for app open - skipping recovery")
                 return
            }

            // Set recovery in progress and clear background disconnection flag
            self.isRecoveryInProgress = true
            self.wasDisconnectedWhileInBackground = false
            os_log(.info, log: self.logger, "📱 App Open Recovery: Starting (blocking other recovery methods)")

            DispatchQueue.main.async { [weak self] in
                self?.executeAppOpenRecovery()
            }
        }
    }
    
    private func executeAppOpenRecovery() {
        
        let savedIndex = UserDefaults.standard.integer(forKey: "lyrplay_recovery_index")
        let savedPosition = UserDefaults.standard.double(forKey: "lyrplay_recovery_position")
        
        guard savedPosition > 0 else {
            os_log(.info, log: logger, "📱 No saved position for app open - skipping recovery")
            isRecoveryInProgress = false // Clear recovery flag
            return
        }
        
        os_log(.info, log: logger, "📱 Performing app open recovery: jump to track %d at %.2f seconds (will pause)", savedIndex, savedPosition)
        
        // Use Home Assistant approach: playlist jump with timeOffset AND pause
        let playlistJumpCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, [
                "playlist", "jump", savedIndex, 1, 1, [
                    "timeOffset": savedPosition
                ]
            ]]
        ]
        
        sendJSONRPCCommandDirect(playlistJumpCommand) { [weak self] response in
            os_log(.info, log: self?.logger ?? OSLog.default, "📱 App open recovery completed - positioned silently with noplay=1")
            
            // No pause needed since noplay=1 keeps it paused automatically
            // Refresh WebView to show updated position/state
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                SettingsManager.shared.shouldReloadWebView = true
                os_log(.info, log: self?.logger ?? OSLog.default, "🔄 WebView refresh triggered after app open recovery")
            }
            
            // Clear recovery flag after completion
            self?.isRecoveryInProgress = false
            os_log(.info, log: self?.logger ?? OSLog.default, "📱 Recovery state cleared - other recovery methods can now proceed")
            
            // Clear recovery data after successful use
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_index")
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_position")
            UserDefaults.standard.removeObject(forKey: "lyrplay_recovery_timestamp")
        }
    }
    
}

// MARK: - SlimProtoClientDelegate
extension SlimProtoCoordinator: SlimProtoClientDelegate {
    
    func slimProtoDidConnect() {
        os_log(.info, log: logger, "✅ Connection established")
        connectionManager.didConnect()
        
        // Don't start any status timers here
        // Heartbeat only starts during playback
        
        startServerTimeSync()
        setupNowPlayingManagerIntegration()
        
        
        // Removed custom position recovery - server auto-resume handles position recovery
    }

    func slimProtoDidDisconnect(error: Error?) {
        os_log(.info, log: logger, "🔌 Connection lost")
        
        // Track if we were disconnected while in background (for app open recovery)
        if isAppInBackground {
            wasDisconnectedWhileInBackground = true
            os_log(.info, log: logger, "📱 Disconnected while in background - recovery will be needed")
        }
        
        // CRITICAL: Save position for playlist recovery on any disconnect
        saveCurrentPositionForRecovery()
        
        connectionManager.didDisconnect(error: error)
        
        stopPlaybackHeartbeat()  // ← Correct timer
        stopServerTimeSync()
    }
    
    func slimProtoDidReceiveCommand(_ command: SlimProtoCommand) {
        // Record that we received a command (shows connection is alive)
        connectionManager.recordHeartbeatResponse()
        
        // Forward to command handler
        commandHandler.processCommand(command)
    }
}

// MARK: - Enhanced SlimProtoConnectionManagerDelegate
extension SlimProtoCoordinator: SlimProtoConnectionManagerDelegate {
    
    func connectionManagerShouldReconnect() {
        os_log(.info, log: logger, "🔄 Connection manager requesting reconnection")
        
        // Try backup server if primary fails and backup is available
        if settings.currentActiveServer == .primary &&
           settings.isBackupServerEnabled &&
           !settings.backupServerHost.isEmpty {
            
            os_log(.info, log: logger, "🔄 Primary server failed - trying backup server")
            settings.switchToBackupServer()
            
            // Update client with backup server settings
            client.updateServerSettings(
                host: settings.activeServerHost,
                port: UInt16(settings.activeServerSlimProtoPort)
            )
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
        
        os_log(.info, log: logger, "🔍 Pause state - lockScreen: %{public}s, player: %{public}s", 
               isLockScreenPaused ? "YES" : "NO", playerState)
        
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
    
    
    private func saveServerVolumeAndMute() {
        guard !isSavingVolume else {
            os_log(.info, log: logger, "⚠️ Volume save already in progress - skipping duplicate call")
            return
        }
        
        isSavingVolume = true
        os_log(.info, log: logger, "🔇 Saving current server volume and muting for silent recovery")
        
        let playerID = settings.playerMACAddress
        
        // Get current volume from server
        let getVolumeCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["mixer", "volume", "?"]]
        ]
        
        sendJSONRPCCommandDirect(getVolumeCommand) { [weak self] response in
            guard let self = self else { return }
            
            if let result = response["result"] as? [String: Any],
               let volume = result["_volume"] as? String {
                
                os_log(.info, log: self.logger, "📊 Current server volume to save: %{public}s", volume)
                
                // Save volume locally as backup in case server preferences fail
                UserDefaults.standard.set(volume, forKey: "lastServerVolume")
                
                // Save current volume to preferences
                let saveVolumeCommand: [String: Any] = [
                    "id": 1,
                    "method": "slim.request", 
                    "params": [playerID, ["playerpref", "lyrPlaySavedVolume", volume]]
                ]
                
                self.sendJSONRPCCommandDirect(saveVolumeCommand) { _ in
                    os_log(.info, log: self.logger, "💾 Saved current volume: %{public}s", volume)
                    
                    // Now mute the server volume
                    let muteCommand: [String: Any] = [
                        "id": 1,
                        "method": "slim.request",
                        "params": [playerID, ["mixer", "volume", "0"]]
                    ]
                    
                    self.sendJSONRPCCommandDirect(muteCommand) { _ in
                        os_log(.info, log: self.logger, "🔇 Server volume muted for silent recovery")
                        
                        // Reset save flag when complete
                        self.isSavingVolume = false
                    }
                }
            } else {
                os_log(.error, log: self.logger, "❌ Failed to get current server volume")
                self.isSavingVolume = false
            }
        }
    }
    
    private func restoreServerVolume() {
        guard !isRestoringVolume else {
            os_log(.info, log: logger, "⚠️ Volume restore already in progress - skipping duplicate call")
            return
        }
        
        isRestoringVolume = true
        os_log(.info, log: logger, "🔊 Restoring server volume after recovery")
        
        let playerID = settings.playerMACAddress
        
        // Get saved volume from preferences
        let getSavedVolumeCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playerpref", "lyrPlaySavedVolume", "?"]]
        ]
        
        sendJSONRPCCommandDirect(getSavedVolumeCommand) { [weak self] response in
            guard let self = self else { return }
            
            if let result = response["result"] as? [String: Any],
               let savedVolume = result["_p2"] as? String,
               !savedVolume.isEmpty {
                
                // Restore the saved volume
                let restoreVolumeCommand: [String: Any] = [
                    "id": 1,
                    "method": "slim.request",
                    "params": [playerID, ["mixer", "volume", savedVolume]]
                ]
                
                self.sendJSONRPCCommandDirect(restoreVolumeCommand) { _ in
                    os_log(.info, log: self.logger, "🔊 Server volume restored to: %{public}s", savedVolume)
                    
                    // Clear the saved volume preference
                    let clearVolumeCommand: [String: Any] = [
                        "id": 1,
                        "method": "slim.request",
                        "params": [playerID, ["playerpref", "lyrPlaySavedVolume", ""]]
                    ]
                    
                    self.sendJSONRPCCommandDirect(clearVolumeCommand) { _ in }
                    
                    // Also clear local backup since server restore succeeded
                    UserDefaults.standard.removeObject(forKey: "lastServerVolume")
                    
                    // Reset volume restore flag
                    self.isRestoringVolume = false
                }
            } else {
                // Try local backup if server preferences failed
                if let backupVolume = UserDefaults.standard.string(forKey: "lastServerVolume"),
                   !backupVolume.isEmpty {
                    
                    os_log(.info, log: self.logger, "💾 Using local backup volume: %{public}s", backupVolume)
                    
                    // Restore using backup volume
                    let restoreVolumeCommand: [String: Any] = [
                        "id": 1,
                        "method": "slim.request",
                        "params": [playerID, ["mixer", "volume", backupVolume]]
                    ]
                    
                    self.sendJSONRPCCommandDirect(restoreVolumeCommand) { _ in
                        os_log(.info, log: self.logger, "🔊 Server volume restored from backup: %{public}s", backupVolume)
                        
                        // Clear the backup since it was used successfully
                        UserDefaults.standard.removeObject(forKey: "lastServerVolume")
                        
                        // Reset volume restore flag
                        self.isRestoringVolume = false
                    }
                } else {
                    os_log(.info, log: self.logger, "ℹ️ No saved volume found - leaving current volume unchanged")
                    
                    // Reset volume restore flag even when no volume found
                    self.isRestoringVolume = false
                }
            }
        }
    }
    
    private func resetVolumeFlags() {
        // Reset both flags in case of errors or completion
        isSavingVolume = false
        isRestoringVolume = false
        os_log(.debug, log: logger, "🔄 Volume flags reset")
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
    
    func didStartStream(url: String, format: String, startTime: Double) {
        os_log(.info, log: logger, "🎵 Starting stream: %{public}s from %.2f", format, startTime)
        
        // Stop any existing playback and timers first
        audioManager.stop()
        stopPlaybackHeartbeat()
        
        // Start the new stream - this will trigger the sequence:
        // 1. handleStartCommand sends STMf (already done by command handler)
        // 2. AudioPlayer intercepts headers → RESP
        // 3. StreamingKit starts buffering → STMc (via delegate)
        // 4. Playback actually starts → STMs (below)
        if startTime > 0 {
            audioManager.playStreamAtPositionWithFormat(urlString: url, startTime: startTime, format: format)
        } else {
            audioManager.playStreamWithFormat(urlString: url, format: format)
        }
        
        // Start periodic server time fetching for lock screen updates
        startServerTimeFetching()
        
        // Start the 1-second heartbeat timer (like squeezelite)
        startPlaybackHeartbeat()
        
        // Get metadata and sync with server
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.fetchCurrentTrackMetadata()
            
            // Check if this is a radio stream and start automatic refresh
            if url.contains("stream") || url.contains("radio") || url.contains("live") ||
               url.contains(".pls") || url.contains(".m3u") || url.hasPrefix("http") {
                self.startMetadataRefreshForRadio()
            }
        }
        
        // Fetch server time after connection stabilizes
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.fetchServerTime()
        }
    }
    
    func didPauseStream() {
        os_log(.info, log: logger, "⏸️ Server pause command")
        
        // CRITICAL FIX: Update SimpleTimeTracker with pause state
        let currentTime = simpleTimeTracker.getCurrentTimeDouble()
        simpleTimeTracker.updateFromServer(time: currentTime, playing: false)
        
        // Normal foreground or background pause - let background handler deal with position saving
        audioManager.pause()
        stopPlaybackHeartbeat()
        
        if !isAppInBackground {
            client.sendStatus("STMp")
        }
    }

    func didResumeStream() {
        os_log(.info, log: logger, "▶️ Server unpause command")
        
        // CRITICAL FIX: Update SimpleTimeTracker with resume state
        let currentTime = simpleTimeTracker.getCurrentTimeDouble()
        simpleTimeTracker.updateFromServer(time: currentTime, playing: true)
        
        audioManager.play()
        
        // Restart heartbeat when resumed
        startPlaybackHeartbeat()
        
        // Restart metadata refresh for radio streams after resume
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Simplified: Just fetch metadata if timer isn't running
            if self.metadataRefreshTimer == nil {
                self.fetchCurrentTrackMetadata()
            }
        }
        
        client.sendStatus("STMr")
    }

    func didStopStream() {
        os_log(.info, log: logger, "⏹️ Server stop command")
        
        audioManager.stop()
        
        // Stop periodic server time fetching
        stopServerTimeFetching()
        
        // Stop heartbeat when stopped
        stopPlaybackHeartbeat()
        
        // Stop metadata refresh for radio streams
        stopMetadataRefresh()
        
        client.sendStatus("STMf")
    }
    
    func getCurrentAudioTime() -> Double {
        return audioManager.getCurrentTime()
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
        
        os_log(.debug, log: logger, "📍 Updated server time: %.2f (playing: %{public}s) [Material-style]", 
               position, isPlaying ? "YES" : "NO")
    }
    
    /// Fetch actual server time via JSON-RPC (not audio player time)
    func fetchServerTime() {
        guard !settings.activeServerHost.isEmpty else {
            return
        }
        
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
            return
        }
        
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any] else {
                return
            }
            
            // Extract REAL server time from server response
            let serverTime = result["time"] as? Double ?? 0.0
            let duration = result["duration"] as? Double ?? 0.0
            let mode = result["mode"] as? String ?? "stop"
            let isPlaying = (mode == "play")
            
            // Update our time tracking with REAL server time
            updateServerTime(position: serverTime, duration: duration, isPlaying: isPlaying)
            
            os_log(.info, log: logger, "📡 Real server time fetched: %.2f (playing: %{public}s)", 
                   serverTime, isPlaying ? "YES" : "NO")
            
        } catch {
            os_log(.error, log: logger, "❌ Failed to parse server time response: %{public}s", error.localizedDescription)
        }
    }
    
    /// Get current interpolated time (Material-style approach only)
    func getCurrentInterpolatedTime() -> (time: Double, playing: Bool) {
        // SIMPLIFIED: Use only SimpleTimeTracker (Material-style approach)
        return simpleTimeTracker.getCurrentTime()
    }
    
    /// Get current time for position saving
    func getCurrentTimeForSaving() -> Double {
        let (time, _) = getCurrentInterpolatedTime()
        return time
    }
    
    /// Get SimpleTimeTracker for debugging (Material-style system)
    func getSimpleTimeTracker() -> SimpleTimeTracker {
        return simpleTimeTracker
    }
    
    /// Handle track end detection from server time (replaces unreliable BASS_SYNC_END)
    func handleTrackEndFromServerTime() {
        os_log(.info, log: logger, "🎵 Track end detected via server time - forwarding to command handler")
        commandHandler.notifyTrackEnded()
    }
    
    /// Set WebView reference for Material UI refresh
    func setWebView(_ webView: WKWebView) {
        self.webView = webView
        os_log(.info, log: logger, "✅ WebView reference set for Material UI refresh")
    }
    
    /// Public method to refresh Material UI (can be called externally)
    func refreshMaterialInterface() {
        // Removed refreshMaterialUI() method - server auto-resume handles position recovery
    }
    
    /// Start periodic server time fetching
    func startServerTimeFetching() {
        stopServerTimeFetching() // Stop any existing timer
        
        // Fetch immediately
        fetchServerTime()
        
        // Start periodic timer (every 8 seconds)
        serverTimeTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.fetchServerTime()
        }
        
        os_log(.debug, log: logger, "🔄 Started periodic server time fetching")
    }
    
    /// Stop periodic server time fetching
    func stopServerTimeFetching() {
        serverTimeTimer?.invalidate()
        serverTimeTimer = nil
        os_log(.debug, log: logger, "⏹️ Stopped periodic server time fetching")
    }
}

// MARK: - Enhanced Lock Screen Integration with SlimProto Connection Fix
extension SlimProtoCoordinator {
    
    func sendLockScreenCommand(_ command: String) {
        os_log(.info, log: logger, "🔒 Lock Screen command: %{public}s", command)
        
        // CRITICAL: Always activate audio session for lock screen commands (ensures iOS readiness)
        audioManager.activateAudioSession()
        
        // Ensure connection and send command
        if !connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "🔄 Reconnecting for lock screen command")
            connect()
            
            // Queue command to send after connection
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if command.lowercased() == "play" {
                    // Use playlist jump with timeOffset for position recovery
                    self.performPlaylistRecovery()
                } else {
                    self.sendJSONRPCCommand(command)
                }
            }
        } else {
            // Connected - send command immediately (no position saving needed)
            os_log(.info, log: logger, "🔒 Already connected - sending lock screen command directly")
            sendJSONRPCCommand(command)
        }
        
        // Track lock screen pause state
        if command.lowercased() == "pause" {
            commandHandler.isPausedByLockScreen = true
        }
    }
    
    private func sendPowerCommand(_ state: String) {
        let playerID = settings.playerMACAddress
        let powerCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["power", state]]
        ]
        
        sendJSONRPCCommandDirect(powerCommand) { [weak self] response in
            os_log(.info, log: self?.logger ?? OSLog.default, "🔌 Power command sent: power %{public}s", state)
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
                        
                        // CRITICAL FIX: Check if stream was invalidated for CarPlay
                        if self.audioManager.getPlayerState() == "No Stream" {
                            os_log(.info, log: self.logger, "🚗 PLAY command with no active stream - likely invalidated for CarPlay")
                            os_log(.info, log: self.logger, "🚗 Forcing fresh stream creation like NEXT/PREVIOUS commands")
                            
                            // Force fresh stream creation by requesting current track status
                            // This mimics what NEXT/PREVIOUS commands do to get fresh streams
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                os_log(.info, log: self.logger, "🚗 Requesting fresh metadata to trigger stream creation")
                                self.fetchCurrentTrackMetadata()
                            }
                        }
                    }
                    
                    // For skip commands, refresh metadata and resume server time sync
                    if command == "next" || command == "previous" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self.fetchCurrentTrackMetadata()
                            
                            // CRITICAL: Resume server time sync after track skip
                            // This ensures we get fresh server time for the new track
                            os_log(.debug, log: self.logger, "▶️ Resuming server time sync after track skip")
                            
                            // Force immediate sync to get current position of new track
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                // Server time sync will continue automatically
                            }
                        }
                    }
                }
            }
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Sent JSON-RPC %{public}s command to LMS", command)
    }
    
    
    
    
    // Direct JSON-RPC command sender for preference testing
    private func sendJSONRPCCommandDirect(_ jsonRPC: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        os_log(.info, log: logger, "🌐 Sending JSON-RPC command: %{public}s", String(describing: jsonRPC))
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "❌ Failed to create JSON-RPC command")
            completion([:])
            return
        }
        
        let urlString = "\(settings.webURL)jsonrpc.js"
        os_log(.info, log: logger, "🌐 JSON-RPC URL: %{public}s", urlString)
        
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "❌ Invalid JSON-RPC URL: %{public}s", urlString)
            completion([:])
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 5.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: self.logger, "❌ JSON-RPC request failed: %{public}s", error.localizedDescription)
                completion([:])
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                os_log(.info, log: self.logger, "🌐 JSON-RPC response status: %d", httpResponse.statusCode)
            }
            
            guard let data = data else {
                os_log(.error, log: self.logger, "❌ No data received from JSON-RPC request")
                completion([:])
                return
            }
            
            do {
                if let jsonResult = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    os_log(.info, log: self.logger, "✅ JSON-RPC response: %{public}s", String(describing: jsonResult))
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
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: self.logger, "Enhanced metadata request failed: %{public}s", error.localizedDescription)
                return
            }
            
            guard let data = data else {
                os_log(.error, log: self.logger, "No enhanced metadata received")
                return
            }
            
            self.parseTrackMetadata(data: data)
        }
        
        task.resume()
        os_log(.debug, log: logger, "🌐 Requesting enhanced track metadata")
    }
    
    // SIMPLIFIED: parseTrackMetadata method using Material skin approach
    private func parseTrackMetadata(data: Data) {
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
                
                // SIMPLIFIED: Basic artwork detection
                var artworkURL: String? = nil
                if let artwork = firstTrack["artwork_url"] as? String, !artwork.isEmpty {
                    artworkURL = artwork.hasPrefix("http") ? artwork : "http://\(settings.activeServerHost):\(settings.activeServerWebPort)\(artwork)"
                } else if let coverid = firstTrack["coverid"] as? String, !coverid.isEmpty, coverid != "0" {
                    artworkURL = "http://\(settings.activeServerHost):\(settings.activeServerWebPort)/music/\(coverid)/cover.jpg"
                }
                
                // Log final metadata result
                os_log(.info, log: logger, "🎵 Material-style: '%{public}s' by %{public}s%{public}s",
                       trackTitle, trackArtist, artworkURL != nil ? " [artwork]" : "")
                
                DispatchQueue.main.async {
                    // Only update duration if server explicitly provides it (Material skin approach)
                    if let duration = serverDuration, duration > 0.0 {
                        self.audioManager.updateTrackMetadata(
                            title: trackTitle,
                            artist: trackArtist,
                            album: trackAlbum,
                            artworkURL: artworkURL,
                            duration: duration
                        )
                    } else {
                        // Don't update duration - preserve existing duration
                        self.audioManager.updateTrackMetadata(
                            title: trackTitle,
                            artist: trackArtist,
                            album: trackAlbum,
                            artworkURL: artworkURL
                            // duration parameter omitted - keeps existing duration
                        )
                    }
                }
                
            } else {
                os_log(.error, log: logger, "Failed to parse metadata response")
            }
        } catch {
            os_log(.error, log: logger, "JSON parsing error: %{public}s", error.localizedDescription)
        }
    }    
    // MARK: - Helper Method to Determine Source Type
    private func determineSourceType(from trackData: [String: Any]) -> String {
        // Check various indicators to determine the source type
        
        // Check for Radio Paradise specific fields
        if let url = trackData["url"] as? String {
            if url.contains("radioparadise.com") {
                return "Radio Paradise"
            }
            if url.contains("tunein.com") || url.contains("radiotime.com") {
                return "TuneIn Radio"
            }
            if url.contains("somafm.com") {
                return "SomaFM"
            }
            if url.contains("spotify.com") {
                return "Spotify"
            }
            if url.contains("tidal.com") {
                return "Tidal"
            }
            if url.contains("qobuz.com") {
                return "Qobuz"
            }
            // Generic radio stream detection
            if url.contains(".pls") || url.contains(".m3u") || url.contains("stream") {
                return "Internet Radio"
            }
        }
        
        // Check for remote_title which often indicates streaming
        if trackData["remote_title"] != nil {
            return "Internet Radio"
        }
        
        // Check for plugin-specific fields
        if trackData["icon"] != nil || trackData["image"] != nil {
            return "Plugin Stream"
        }
        
        // Check if it has a file path (local music)
        if let trackID = trackData["id"] as? Int, trackID > 0 {
            return "Local Music"
        }
        
        return "Unknown Source"
    }
    
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




    // Add this new method for seeking via JSON-RPC
    private func sendSeekCommand(to position: Double, completion: @escaping (Bool) -> Void) {
        let playerID = settings.playerMACAddress
        let clampedPosition = max(0, position)
        
        // FIXED: Use correct JSON-RPC format for time seeking
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["time", clampedPosition]]  // ✅ Pass number directly, not as string
        ] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "Failed to create seek JSON-RPC command")
            completion(false)
            return
        }
        
        let webPort = settings.activeServerWebPort
        let host = settings.activeServerHost
        guard let url = URL(string: "http://\(host):\(webPort)/jsonrpc.js") else {
            os_log(.error, log: logger, "Invalid server URL for seek command")
            completion(false)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        request.timeoutInterval = 8.0
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    os_log(.error, log: self.logger, "Seek command failed: %{public}s", error.localizedDescription)
                    completion(false)
                } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    os_log(.info, log: self.logger, "✅ Seek command sent successfully to %.2f", clampedPosition)
                    
                    // Fetch fresh server time after seek to update lock screen
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.fetchServerTime()
                    }
                    
                    completion(true)
                } else {
                    os_log(.error, log: self.logger, "Seek command failed with HTTP error")
                    completion(false)
                }
            }
        }
        
        task.resume()
        os_log(.info, log: logger, "🌐 Sending seek command to %.2f seconds", clampedPosition)
    }
    
    // MARK: - Volume Control
    func setPlayerVolume(_ volume: Float) {
        // REMOVED: Noisy volume logs - os_log(.debug, log: logger, "🔊 Setting player volume: %.2f", volume)
        audioManager.setVolume(volume)
    }

    func getPlayerVolume() -> Float {
        return audioManager.getVolume()
    }
}

// MARK: - Background Strategy Extension
extension SlimProtoConnectionManager.BackgroundStrategy {
    var description: String {
        switch self {
        case .normal: return "normal"
        case .reduced: return "reduced"
        case .minimal: return "minimal"
        case .suspended: return "suspended"
        }
    }
}
