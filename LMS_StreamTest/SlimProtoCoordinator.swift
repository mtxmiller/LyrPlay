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
    
    // MARK: - Simple Position Recovery
    private var savedPosition: Double = 0.0
    private var savedPositionTimestamp: Date?
    private var shouldResumeOnPlay: Bool = false
    private var isLockScreenPlayRecovery: Bool = false
    
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
        os_log(.info, log: logger, "🔌 Disconnecting from server")
        connectionManager.userInitiatedDisconnection()
        // DON'T stop server time sync immediately - preserve last known good time for lock screen
        // stopServerTimeSync()
        client.disconnect()
    }
    
    func restartConnection() async {
        os_log(.info, log: logger, "🔄 Restarting connection to apply new capabilities...")
        
        // Disconnect from server
        disconnect()
        
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
        disconnect()
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
        
        // Check if we need to recover position after reconnection
        checkForPositionRecoveryAfterConnection()
        
        // Check for custom position recovery from server preferences (app open recovery)
        // Only run if this is NOT a lock screen play recovery
        if !isLockScreenPlayRecovery {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.checkForServerPreferencesRecovery()
            }
        } else {
            os_log(.info, log: logger, "⚠️ Skipping custom position recovery - lock screen recovery in progress")
        }
    }

    func slimProtoDidDisconnect(error: Error?) {
        os_log(.info, log: logger, "🔌 Connection lost")
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
        
        let isLockScreenPaused = commandHandler.isPausedByLockScreen
        let playerState = audioManager.getPlayerState()
        
        os_log(.info, log: logger, "🔍 Pause state - lockScreen: %{public}s, player: %{public}s", 
               isLockScreenPaused ? "YES" : "NO", playerState)
        
        // ALWAYS save position when backgrounding (for lock screen recovery AND app open recovery)
        os_log(.info, log: logger, "💾 Saving position for potential recovery")
        saveCurrentPositionLocally()
        savePositionToServerPreferences()
        
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
        
        // CRITICAL: Clear lock screen recovery flag when app opens normally
        // App-open should use normal app-open recovery, not lock screen recovery
        isLockScreenPlayRecovery = false
        os_log(.info, log: logger, "📱 App foregrounded - cleared lock screen recovery flag")
        
        if connectionManager.connectionState.isConnected {
            // Check if we need to recover position after being backgrounded
            checkForPositionRecoveryOnForeground()
        } else {
            // Will connect and potentially recover position
            connect()
        }
    }
    
    // MARK: - Simple Position Recovery Methods
    
    private func saveCurrentPositionLocally() {
        // Use current time immediately (no server fetch needed - we have SimpleTimeTracker)
        let currentTime = self.getCurrentTimeForSaving()
        let audioTime = self.audioManager.getCurrentTime()
        
        os_log(.info, log: self.logger, "🔍 Position sources - Server: %.2f, Audio: %.2f", 
               currentTime, audioTime)
        
        // Use SimpleTimeTracker time as primary source (reliable even when disconnected)
        var positionToSave: Double = 0.0
        var sourceUsed: String = "none"
        
        if currentTime > 0.1 {
            positionToSave = currentTime
            sourceUsed = "SimpleTimeTracker"
            os_log(.info, log: self.logger, "✅ Using SimpleTimeTracker time: %.2f", currentTime)
        }
        // Fallback to audio time only if SimpleTimeTracker unavailable
        else if audioTime > 0.1 {
            positionToSave = audioTime
            sourceUsed = "audio manager (fallback)"
            os_log(.info, log: self.logger, "🔄 SimpleTimeTracker unavailable, using audio time: %.2f", audioTime)
        }
        
        // Only save if we got a valid position
        if positionToSave > 0.1 {
            self.savedPosition = positionToSave
            self.savedPositionTimestamp = Date()
            self.shouldResumeOnPlay = true
            
            os_log(.info, log: self.logger, "💾 Saved position locally: %.2f seconds (from %{public}s)", 
                   positionToSave, sourceUsed)
        } else {
            os_log(.error, log: self.logger, "❌ No valid position to save - Server: %.2f, Audio: %.2f", 
                   currentTime, audioTime)
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
    
    private func checkForServerPreferencesRecovery() {
        os_log(.info, log: logger, "🔍 Checking for custom position recovery from server preferences")
        
        let playerID = settings.playerMACAddress
        
        // Query our saved position
        let queryPositionCommand: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playerpref", "lyrPlayLastPosition", "?"]]
        ]
        
        sendJSONRPCCommandDirect(queryPositionCommand) { [weak self] response in
            self?.handleServerPreferencesRecoveryResponse(response)
        }
    }
    
    private func handleServerPreferencesRecoveryResponse(_ response: [String: Any]?) {
        guard let response = response,
              let result = response["result"] as? [String: Any],
              let positionString = result["_p2"] as? String,
              let savedPosition = Double(positionString),
              savedPosition > 0.1 else {
            os_log(.info, log: logger, "ℹ️ No custom position found in server preferences")
            return
        }
        
        os_log(.info, log: logger, "🎯 Found custom saved position: %.2f seconds - starting recovery", savedPosition)
        
        // Perform custom position recovery
        performCustomPositionRecovery(to: savedPosition)
    }
    
    private func performCustomPositionRecovery(to position: Double) {
        os_log(.info, log: logger, "🔄 Custom recovery: server-muted play → seek → pause sequence to %.2f", position)
        
        // First, save current server volume and mute it for silent recovery
        saveServerVolumeAndMute()
        
        // Wait a moment for server volume to be muted, then start recovery sequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.sendJSONRPCCommand("play")
            
            // Then seek after play starts
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.sendSeekCommand(to: position) { [weak self] seekSuccess in
                guard let self = self else { return }
                
                if seekSuccess {
                    os_log(.info, log: self.logger, "✅ Custom recovery: Seek successful - pausing at recovered position")
                    
                    // Pause at the recovered position
                    self.sendJSONRPCCommand("pause")
                    
                    // Restore server volume after recovery is complete
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.restoreServerVolume()
                        
                        // Clear the custom preferences since we've recovered
                        self.clearServerPreferencesRecovery()
                        
                        // Refresh UI after recovery
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            self.refreshUIAfterRecovery()
                            os_log(.info, log: self.logger, "🎵 Server-muted custom position recovery complete")
                        }
                    }
                } else {
                    os_log(.error, log: self.logger, "❌ Custom recovery: Failed to seek to saved position")
                    
                    // Restore volume even on failure
                    self.restoreServerVolume()
                    
                    // Clear preferences even on failure
                    self.clearServerPreferencesRecovery()
                }
                }
            }
        }
    }
    
    private func clearServerPreferencesRecovery() {
        os_log(.info, log: logger, "🗑️ Clearing custom position recovery preferences")
        
        let playerID = settings.playerMACAddress
        
        let clearCommands: [[String: Any]] = [
            ["id": 1, "method": "slim.request", "params": [playerID, ["playerpref", "lyrPlayLastPosition", ""]]],
            ["id": 1, "method": "slim.request", "params": [playerID, ["playerpref", "lyrPlayLastState", ""]]],
            ["id": 1, "method": "slim.request", "params": [playerID, ["playerpref", "lyrPlaySaveTime", ""]]]
        ]
        
        for command in clearCommands {
            sendJSONRPCCommandDirect(command) { _ in }
        }
    }
    
    private func saveServerVolumeAndMute() {
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
                    }
                }
            }
        }
    }
    
    private func restoreServerVolume() {
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
                    }
                } else {
                    os_log(.info, log: self.logger, "ℹ️ No saved volume found - leaving current volume unchanged")
                }
            }
        }
    }
    
    private func checkForPositionRecoveryOnForeground() {
        // DISABLED: App open recovery disabled - not robust enough for production
        os_log(.info, log: logger, "⚠️ Foreground recovery disabled - too unreliable")
        return
        
        /* DISABLED RECOVERY CODE:
        // Check if we have a saved position that needs recovery
        guard shouldResumeOnPlay,
              let timestamp = savedPositionTimestamp,
              savedPosition > 0.1 else {
            os_log(.info, log: logger, "ℹ️ No position recovery needed on foreground")
            return
        }
        
        // Check if the saved position is recent (within 10 minutes)
        let timeSinceSave = Date().timeIntervalSince(timestamp)
        guard timeSinceSave < 600 else {
            os_log(.info, log: logger, "⚠️ Saved position too old for foreground recovery - clearing")
            clearSavedPosition()
            return
        }
        
        os_log(.info, log: logger, "🔄 App foregrounded with saved position - will recover on next connection")
        END DISABLED RECOVERY CODE */
    }
    
    private func clearSavedPosition() {
        shouldResumeOnPlay = false
        savedPosition = 0.0
        savedPositionTimestamp = nil
        isLockScreenPlayRecovery = false
        os_log(.info, log: logger, "🗑️ Cleared saved position")
    }
    
    private func checkForPositionRecoveryAfterConnection() {
        // REMOVED: Legacy app open recovery - replaced with custom position banking
        os_log(.info, log: logger, "⚠️ Legacy app open recovery removed - using custom position banking instead")
    }
    
    private func performSimplePositionRecoveryAfterConnection() {
        // REMOVED: Legacy app open recovery - replaced with custom position banking
        os_log(.info, log: logger, "⚠️ Legacy app open position recovery removed - using custom position banking instead")
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
    
    func connectionManagerWillSleep() {
        // iOS background time is expiring - disconnect gracefully
        os_log(.info, log: logger, "💤 iOS background time expiring - disconnecting gracefully")
        
        // Save position locally AND to server preferences for bulletproof recovery
        saveCurrentPositionLocally()
        savePositionToServerPreferences()
        
        // Disconnect to conserve resources and battery
        disconnect()
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
                ["status", "-", "1", "tags:u,d,t"]
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
    
    /// Set WebView reference for Material UI refresh
    func setWebView(_ webView: WKWebView) {
        self.webView = webView
        os_log(.info, log: logger, "✅ WebView reference set for Material UI refresh")
    }
    
    /// Public method to refresh Material UI (can be called externally)
    func refreshMaterialInterface() {
        refreshMaterialUI()
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
        
        // CRITICAL: Handle all lock screen play commands to prevent double commands
        if command.lowercased() == "play" {
            isLockScreenPlayRecovery = true
            os_log(.info, log: logger, "🔒 Lock screen play - marked for position recovery")
            
            // Only do position recovery if disconnected - otherwise server knows current position
            if !connectionManager.connectionState.isConnected {
                os_log(.info, log: logger, "🔄 PLAY after disconnect - using simple position recovery")
                
                // CRITICAL: Ensure audio session is active for background playback
                audioManager.activateAudioSession()
                
                // Reconnect and handle position recovery manually
                connect()
                
                // Monitor reconnection and apply saved position
                monitorReconnectionForSimplePositionRecovery()
            } else {
                os_log(.info, log: logger, "🔄 PLAY while connected - server already knows position, sending simple play")
                sendJSONRPCCommand("play")
            }
            return  // CRITICAL: Always return to prevent double command
        }
        
        // For other commands or when connected, use JSON-RPC
        if !connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "❌ No SlimProto connection - starting full reconnection sequence")
            handleDisconnectedLockScreenCommand(command)
            return
        }
        
        // If connected, send command via JSON-RPC (faster) but ensure SlimProto stays connected
        
        // CRITICAL: Track if this is a lock screen pause
        if command.lowercased() == "pause" {
            os_log(.info, log: logger, "🔒 Lock screen PAUSE - marking as lock screen pause")
            commandHandler.isPausedByLockScreen = true
        }
        
        sendJSONRPCCommand(command)
    }
    
    private func handleDisconnectedLockScreenCommand(_ command: String) {
        os_log(.info, log: logger, "🔄 Starting FULL reconnection sequence for: %{public}s", command)
        
        // Step 1: Force stop any existing broken connections
        disconnect()
        
        // Step 2: Wait a moment for cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Step 3: Start fresh connection
            self.connectionManager.resetReconnectionAttempts()
            self.connect()
            
            // Step 4: Monitor connection and send command
            self.waitForConnectionAndExecute(command: command)
        }
    }
    
    private func waitForConnectionAndExecute(command: String, attempt: Int = 0) {
        let maxAttempts = 20 // 20 seconds total wait
        
        if connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "✅ SlimProto reconnected after %d seconds", attempt)
            
            // Send the command via JSON-RPC (faster response)
            sendJSONRPCCommand(command)
            
            // CRITICAL: Also send a SlimProto status to ensure the connection works
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.client.sendStatus("STMt")
                os_log(.info, log: self.logger, "📡 Sent SlimProto heartbeat to verify connection")
            }
            
        } else if attempt < maxAttempts {
            // Keep waiting
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.waitForConnectionAndExecute(command: command, attempt: attempt + 1)
            }
        } else {
            // Timeout - try JSON-RPC only as fallback
            os_log(.error, log: logger, "⏰ SlimProto connection timeout - using JSON-RPC fallback")
            sendJSONRPCCommand(command)
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
    
    // Monitor reconnection and apply simple position recovery
    private func monitorReconnectionForSimplePositionRecovery() {
        os_log(.info, log: logger, "👀 Monitoring reconnection for simple position recovery")
        
        var attempts = 0
        let maxAttempts = 10 // 10 seconds max wait
        
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            
            attempts += 1
            
            if self.connectionManager.connectionState.isConnected {
                os_log(.info, log: self.logger, "✅ Reconnected - applying simple position recovery")
                timer.invalidate()
                
                // Wait a moment for connection to stabilize, then seek and play
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.performSimplePositionRecovery()
                }
                
            } else if attempts >= maxAttempts {
                os_log(.error, log: self.logger, "❌ Reconnection timeout for position recovery")
                timer.invalidate()
            }
        }
    }
    
    private func performSimplePositionRecovery() {
        // DEBUG: Log the current state of saved position variables
        os_log(.info, log: logger, "🔍 Lock screen recovery check - shouldResumeOnPlay: %{public}s, savedPosition: %.2f, timestamp: %{public}s", 
               shouldResumeOnPlay ? "YES" : "NO", savedPosition, 
               savedPositionTimestamp?.description ?? "nil")
        
        // Check if we have a saved position to recover
        guard shouldResumeOnPlay,
              let timestamp = savedPositionTimestamp,
              savedPosition > 0.1 else {
            os_log(.info, log: logger, "ℹ️ No saved position to recover - playing from current position")
            sendJSONRPCCommand("play")
            return
        }
        
        // Check if the saved position is recent (within 10 minutes)
        let timeSinceSave = Date().timeIntervalSince(timestamp)
        guard timeSinceSave < 600 else {
            os_log(.info, log: logger, "⚠️ Saved position too old (%.0f seconds) - playing from current position", timeSinceSave)
            shouldResumeOnPlay = false
            sendJSONRPCCommand("play")
            return
        }
        
        // CRITICAL: Reject stale positions that don't match current server time
        // If saved position is significantly different from current server time, it's probably stale
        let (currentServerTime, _) = getCurrentInterpolatedTime()
        let timeDifference = abs(savedPosition - currentServerTime)
        
        // If current server time is valid and saved position is more than 10 seconds off, reject it
        if currentServerTime > 1.0 && timeDifference > 10.0 {
            os_log(.error, log: logger, "🚨 REJECTING stale position %.2f - server shows %.2f (diff: %.2f)", 
                   savedPosition, currentServerTime, timeDifference)
            clearSavedPosition()
            
            // CRITICAL: Use current server position instead of starting from 0
            os_log(.info, log: logger, "🎯 Using current server position: %.2f seconds instead of stale position", currentServerTime)
            
            // Recover to current server position instead of saved position
            savedPosition = currentServerTime
            // Continue with normal recovery logic using current server position
        }
        
        os_log(.info, log: logger, "🎯 Recovering to saved position: %.2f seconds", savedPosition)
        
        // Lock screen recovery: play → seek → play (fast sequence to minimize audio blip)
        os_log(.info, log: logger, "🔄 Lock screen: play → seek → play sequence (fast)")
        
        // CRITICAL: Pause server time sync during lock screen recovery too
        os_log(.debug, log: logger, "⏸️ Pausing server time sync during lock screen recovery")
        
        sendJSONRPCCommand("play")
        
        // Wait briefly for playback to start, then seek to saved position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            os_log(.info, log: self.logger, "🎯 Now seeking to saved position: %.2f seconds", self.savedPosition)
            
            self.sendSeekCommand(to: self.savedPosition) { [weak self] seekSuccess in
                guard let self = self else { return }
                
                if seekSuccess {
                    os_log(.info, log: self.logger, "✅ Lock screen: Seek successful - continuing playback")
                    
                    // For lock screen recovery, continue playing after seek
                    // No additional play command needed - we're already playing
                } else {
                    os_log(.error, log: self.logger, "❌ Lock screen: Failed to seek to saved position")
                }
                
                // CRITICAL: Resume server time sync after lock screen recovery
                // Wait longer for seek to complete on server before resuming sync
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    os_log(.debug, log: self.logger, "▶️ Resuming server time sync after lock screen recovery")
                    
                    // Force immediate sync to get fresh server time after seek
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        os_log(.debug, log: self.logger, "🔄 Forcing server time sync after seek")
                        // Server time sync will continue automatically
                    }
                }
                
                // Clear the saved position and reset lock screen flag
                self.shouldResumeOnPlay = false
                self.savedPosition = 0.0
                self.savedPositionTimestamp = nil
                self.isLockScreenPlayRecovery = false
                
                os_log(.info, log: self.logger, "🎵 Lock screen recovery complete")
            }
        }
    }
    
    // MARK: - UI Refresh After Recovery
    private func refreshUIAfterRecovery() {
        // CRITICAL: Refresh Material web interface to show correct position after recovery
        DispatchQueue.main.async {
            // Try to refresh Material UI via JavaScript first
            self.refreshMaterialUI()
            
            // Also trigger server time sync as backup
            self.fetchServerTime()
            
            // Notify observers that state may have changed
            self.objectWillChange.send()
            
            os_log(.info, log: self.logger, "✅ Material UI refreshed after recovery")
        }
    }
    
    /// Refresh Material web interface via JavaScript
    private func refreshMaterialUI() {
        guard let webView = webView else {
            os_log(.error, log: logger, "❌ Cannot refresh Material UI - no webView reference")
            return
        }
        
        // Execute JavaScript to trigger Material's refresh mechanism
        let refreshScript = """
        try {
            // Material uses bus.$emit('refreshStatus') to refresh player status
            if (typeof bus !== 'undefined' && bus.$emit) {
                bus.$emit('refreshStatus');
                console.log('✅ Material UI refresh triggered via bus.$emit');
            } else if (typeof refreshStatus === 'function') {
                refreshStatus();
                console.log('✅ Material UI refresh triggered via refreshStatus()');
            } else {
                console.log('❌ Material refresh methods not available');
            }
        } catch (error) {
            console.log('❌ Material refresh error:', error);
        }
        """
        
        webView.evaluateJavaScript(refreshScript) { result, error in
            if let error = error {
                os_log(.error, log: self.logger, "❌ Failed to refresh Material UI: %{public}s", error.localizedDescription)
            } else {
                os_log(.info, log: self.logger, "✅ Material UI refresh JavaScript executed")
            }
        }
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
        
        // Use the same position saving logic as background handling
        saveCurrentPositionLocally()
    }

    func connectionManagerDidReconnectAfterTimeout() {
        os_log(.info, log: logger, "🔒 Reconnected after timeout - checking for position recovery")
        
        // Wait a moment for connection to stabilize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.attemptPositionRecovery()
        }
    }

    // Add this new method for position recovery
    private func attemptPositionRecovery() {
        os_log(.info, log: logger, "🔒 Position recovery temporarily disabled during SlimProto standardization")
        // The server will handle position management through proper SlimProto
        return
    }

    private func performFallbackRecovery(recoveryInfo: (position: Double, wasPlaying: Bool, isValid: Bool), nowPlayingManager: NowPlayingManager) {
        os_log(.info, log: logger, "🔒 Fallback recovery temporarily disabled during SlimProto standardization")
        return
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
