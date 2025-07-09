// File: SlimProtoCoordinator.swift
// Enhanced with ServerTimeSynchronizer for accurate lock screen timing
import Foundation
import os.log
import WebKit

// MARK: - Power-On Resume Preference Types
enum PowerOnResumePreference {
    case noResume           // "noResumeOn"
    case resumePlay         // "resumePlayOn" 
    case resumePlayFromStart // "resumeResetPlayOn"
    
    init(rawValue: String) {
        switch rawValue {
        case "resumePlayOn":
            self = .resumePlay
        case "resumeResetPlayOn": 
            self = .resumePlayFromStart
        case "noResumeOn", "":
            self = .noResume
        default:
            self = .noResume
        }
    }
    
    var rawValue: String {
        switch self {
        case .noResume: return "noResumeOn"
        case .resumePlay: return "resumePlayOn"
        case .resumePlayFromStart: return "resumeResetPlayOn"
        }
    }
    
    var shouldAutoResume: Bool {
        switch self {
        case .resumePlay, .resumePlayFromStart: return true
        case .noResume: return false
        }
    }
    
    var shouldResumeFromStart: Bool {
        switch self {
        case .resumePlayFromStart: return true
        case .resumePlay, .noResume: return false
        }
    }
}

class SlimProtoCoordinator: ObservableObject {
    
    // MARK: - Components
    private let client: SlimProtoClient
    private let commandHandler: SlimProtoCommandHandler
    private let connectionManager: SlimProtoConnectionManager
    private let audioManager: AudioManager
    private let serverTimeSynchronizer: ServerTimeSynchronizer // Keep for compatibility but minimize usage
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
        self.serverTimeSynchronizer = ServerTimeSynchronizer(connectionManager: connectionManager)
        self.simpleTimeTracker = SimpleTimeTracker() // NEW: Initialize Material-style tracker
        
        setupDelegation()
        setupAudioCallbacks()
        setupServerTimeIntegration()
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
        
        // ADD THIS LINE - Connect ServerTimeSynchronizer to command handler
        commandHandler.serverTimeSynchronizer = serverTimeSynchronizer
        
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
    
    private func setupServerTimeIntegration() {
        // DISABLED: Don't connect ServerTimeSynchronizer to NowPlayingManager
        // We're using our simplified system instead
        // audioManager.setupServerTimeIntegration(with: serverTimeSynchronizer)
        os_log(.info, log: logger, "✅ Server time integration disabled (using simplified system)")
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
        DebugLogManager.shared.logInfo("🔌 Disconnecting from server")
        connectionManager.userInitiatedDisconnection()
        // DON'T stop server time sync immediately - preserve last known good time for lock screen
        // stopServerTimeSync()
        client.disconnect()
    }
    
    func updateServerSettings(host: String, port: UInt16) {
        // Store current settings for change detection
        lastKnownHost = host
        lastKnownPort = port
        
        // Update the client
        client.updateServerSettings(host: host, port: port)
        
        os_log(.info, log: logger, "Server settings updated and tracked - Host: %{public}s, Port: %d", host, port)
    }
    
    // MARK: - Server Time Sync Management (DISABLED - using simplified SlimProto tracking)
    private func startServerTimeSync() {
        serverTimeSynchronizer.startSyncing() // Keep for compatibility
        os_log(.debug, log: logger, "🔄 Using simplified SlimProto time tracking")
    }
    
    private func stopServerTimeSync() {
        serverTimeSynchronizer.stopSyncing() // Keep for compatibility
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
    
    // Helper method to restart radio metadata refresh if it's not running
    private func ensureRadioMetadataRefreshIsRunning() {
        if metadataRefreshTimer == nil {
            // For now, just restart metadata refresh - we'll rely on the timer to determine if it's radio
            os_log(.info, log: logger, "🔄 Ensuring metadata refresh is running")
            fetchCurrentTrackMetadata()
        }
    }
    
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
        
        os_log(.info, log: logger, "📱 App backgrounded - checking SlimProto recovery strategy")
        DebugLogManager.shared.logInfo("📱 App backgrounded - checking recovery strategy")
        
        let isLockScreenPaused = commandHandler.isPausedByLockScreen
        let playerState = audioManager.getPlayerState()
        
        os_log(.info, log: logger, "🔍 Pause state - lockScreen: %{public}s, player: %{public}s", 
               isLockScreenPaused ? "YES" : "NO", playerState)
        DebugLogManager.shared.logInfo("🔍 Pause state - lockScreen: \(isLockScreenPaused ? "YES" : "NO"), player: \(playerState)")
        
        // SIMPLE STRATEGY: Save position locally when backgrounding while paused
        if playerState == "Paused" || playerState == "Stopped" {
            backgroundedWhilePlaying = false
            os_log(.info, log: logger, "⏸️ App backgrounded while paused - saving position locally")
            DebugLogManager.shared.logInfo("⏸️ App backgrounded while paused - saving position locally")
            
            // Save position using current SlimProto time data
            os_log(.info, log: logger, "💾 Saving position using current SlimProto time")
            DebugLogManager.shared.logInfo("💾 Saving position using current SlimProto time")
            
            saveCurrentPositionLocally()
            
            // Continue with disconnect after saving position
            os_log(.info, log: logger, "🔌 Disconnecting normally - position saved locally")
            DebugLogManager.shared.logInfo("🔌 Disconnecting normally - position saved locally")
            disconnect()
            
            return // Don't continue with immediate disconnect
        } else {
            backgroundedWhilePlaying = true
            os_log(.info, log: logger, "▶️ App backgrounded while playing - monitoring for pause after backgrounding")
            DebugLogManager.shared.logInfo("▶️ App backgrounded while playing - monitoring for pause after backgrounding")
            // Keep connection alive for active playback, but monitor for pause
        }
    }
    
    func connectionManagerDidEnterForeground() {
        isAppInBackground = false
        backgroundedWhilePlaying = false
        
        // CRITICAL: Clear lock screen recovery flag when app opens normally
        // App-open should use normal app-open recovery, not lock screen recovery
        isLockScreenPlayRecovery = false
        os_log(.info, log: logger, "📱 App foregrounded - cleared lock screen recovery flag")
        DebugLogManager.shared.logInfo("📱 App foregrounded - cleared lock screen recovery flag")
        
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
        DebugLogManager.shared.logInfo("🔍 Position sources - Server: \(String(format: "%.2f", currentTime)), Audio: \(String(format: "%.2f", audioTime))")
        
        // Use SimpleTimeTracker time as primary source (reliable even when disconnected)
        var positionToSave: Double = 0.0
        var sourceUsed: String = "none"
        
        if currentTime > 0.1 {
            positionToSave = currentTime
            sourceUsed = "SimpleTimeTracker"
            os_log(.info, log: self.logger, "✅ Using SimpleTimeTracker time: %.2f", currentTime)
            DebugLogManager.shared.logInfo("✅ Using SimpleTimeTracker time: \(String(format: "%.2f", currentTime))")
        }
        // Fallback to audio time only if SimpleTimeTracker unavailable
        else if audioTime > 0.1 {
            positionToSave = audioTime
            sourceUsed = "audio manager (fallback)"
            os_log(.info, log: self.logger, "🔄 SimpleTimeTracker unavailable, using audio time: %.2f", audioTime)
            DebugLogManager.shared.logInfo("🔄 SimpleTimeTracker unavailable, using audio time: \(String(format: "%.2f", audioTime))")
        }
        
        // Only save if we got a valid position
        if positionToSave > 0.1 {
            self.savedPosition = positionToSave
            self.savedPositionTimestamp = Date()
            self.shouldResumeOnPlay = true
            
            os_log(.info, log: self.logger, "💾 Saved position locally: %.2f seconds (from %{public}s)", 
                   positionToSave, sourceUsed)
            DebugLogManager.shared.logInfo("💾 Saved position locally: \(String(format: "%.2f", positionToSave)) seconds (from \(sourceUsed))")
        } else {
            os_log(.error, log: self.logger, "❌ No valid position to save - Server: %.2f, Audio: %.2f", 
                   currentTime, audioTime)
            DebugLogManager.shared.logError("❌ No valid position to save - Server: \(String(format: "%.2f", currentTime)), Audio: \(String(format: "%.2f", audioTime))")
        }
    }
    
    private func checkForPositionRecoveryOnForeground() {
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
            DebugLogManager.shared.logWarning("⚠️ Saved position too old for foreground recovery - clearing")
            clearSavedPosition()
            return
        }
        
        os_log(.info, log: logger, "🔄 App foregrounded with saved position - will recover on next connection")
        DebugLogManager.shared.logInfo("🔄 App foregrounded with saved position - will recover on next connection")
    }
    
    private func clearSavedPosition() {
        shouldResumeOnPlay = false
        savedPosition = 0.0
        savedPositionTimestamp = nil
        isLockScreenPlayRecovery = false
        os_log(.info, log: logger, "🗑️ Cleared saved position")
        DebugLogManager.shared.logInfo("🗑️ Cleared saved position")
    }
    
    private func checkForPositionRecoveryAfterConnection() {
        // Skip if this is a lock screen play recovery (handled separately)
        if isLockScreenPlayRecovery {
            os_log(.info, log: logger, "ℹ️ Skipping app-open recovery - this is lock screen play recovery")
            DebugLogManager.shared.logInfo("ℹ️ Skipping app-open recovery - this is lock screen play recovery")
            return
        }
        
        // DEBUG: Always log the current saved position state
        os_log(.info, log: logger, "🔍 Recovery check - savedPosition: %.2f, shouldResumeOnPlay: %{public}s, timestamp: %{public}s", 
               savedPosition, shouldResumeOnPlay ? "YES" : "NO", 
               savedPositionTimestamp?.description ?? "nil")
        DebugLogManager.shared.logInfo("🔍 Recovery check - savedPosition: \(String(format: "%.2f", savedPosition)), shouldResumeOnPlay: \(shouldResumeOnPlay ? "YES" : "NO"), timestamp: \(savedPositionTimestamp?.description ?? "nil")")
        
        // Check if we have a saved position that needs recovery
        guard shouldResumeOnPlay,
              let timestamp = savedPositionTimestamp,
              savedPosition > 0.1 else {
            os_log(.info, log: logger, "ℹ️ No position recovery needed after connection")
            return
        }
        
        // Check if the saved position is recent (within 10 minutes)
        let timeSinceSave = Date().timeIntervalSince(timestamp)
        guard timeSinceSave < 600 else {
            os_log(.info, log: logger, "⚠️ Saved position too old after connection (%.0f seconds) - clearing", timeSinceSave)
            DebugLogManager.shared.logWarning("⚠️ Saved position too old after connection (\(Int(timeSinceSave)) seconds) - clearing")
            clearSavedPosition()
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
            DebugLogManager.shared.logError("🚨 REJECTING stale position \(String(format: "%.2f", savedPosition)) - server shows \(String(format: "%.2f", currentServerTime)) (diff: \(String(format: "%.2f", timeDifference)))")
            clearSavedPosition()
            return
        }
        
        os_log(.info, log: logger, "🎯 Connection established with saved position - will recover after stabilization")
        DebugLogManager.shared.logInfo("🎯 Connection established with saved position - will recover after stabilization")
        
        // Wait for connection to stabilize, then seek to saved position
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.performSimplePositionRecoveryAfterConnection()
        }
    }
    
    private func performSimplePositionRecoveryAfterConnection() {
        // This is for when app is opened and reconnects (not lock screen play)
        // We seek to position but DON'T automatically start playing
        
        guard shouldResumeOnPlay,
              let timestamp = savedPositionTimestamp,
              savedPosition > 0.1 else {
            os_log(.info, log: logger, "ℹ️ No saved position to recover after connection")
            return
        }
        
        // Double-check age
        let timeSinceSave = Date().timeIntervalSince(timestamp)
        guard timeSinceSave < 600 else {
            os_log(.info, log: logger, "⚠️ Position too old - not recovering")
            clearSavedPosition()
            return
        }
        
        os_log(.info, log: logger, "🎯 Recovering to saved position after app open: %.2f seconds", savedPosition)
        DebugLogManager.shared.logInfo("🎯 Recovering to saved position after app open: \(String(format: "%.2f", savedPosition)) seconds")
        
        // App open recovery: play → seek → pause (fast sequence to minimize audio blip)
        os_log(.info, log: logger, "🔄 App open: play → seek → pause sequence (fast)")
        DebugLogManager.shared.logInfo("🔄 App open: play → seek → pause sequence (fast)")
        
        // CRITICAL: Pause server time sync during recovery to prevent crazy time jumps
        os_log(.debug, log: logger, "⏸️ Pausing server time sync during recovery")
        
        sendJSONRPCCommand("play")
        
        // Wait briefly for playback to start, then seek, then pause immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            os_log(.info, log: self.logger, "🎯 App open: Now seeking to saved position: %.2f seconds", self.savedPosition)
            DebugLogManager.shared.logInfo("🎯 App open: Now seeking to saved position: \(String(format: "%.2f", self.savedPosition)) seconds")
            
            self.sendSeekCommand(to: self.savedPosition) { [weak self] seekSuccess in
                guard let self = self else { return }
                
                if seekSuccess {
                    os_log(.info, log: self.logger, "✅ App open: Seek successful - now pausing")
                    DebugLogManager.shared.logInfo("✅ App open: Seek successful - now pausing")
                    
                    // Pause immediately after seeking (no delay)
                    self.sendJSONRPCCommand("pause")
                    os_log(.info, log: self.logger, "⏸️ App open recovery complete - positioned at saved location")
                    DebugLogManager.shared.logInfo("⏸️ App open recovery complete - positioned at saved location")
                    
                    // CRITICAL: Refresh UI after recovery and resume server time sync
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        os_log(.info, log: self.logger, "🔄 Refreshing UI after recovery")
                        DebugLogManager.shared.logInfo("🔄 Refreshing UI after recovery")
                        self.refreshUIAfterRecovery()
                        
                        os_log(.debug, log: self.logger, "▶️ Resuming server time sync after recovery")
                    }
                } else {
                    os_log(.error, log: self.logger, "❌ App open: Failed to seek to saved position")
                    DebugLogManager.shared.logError("❌ App open: Failed to seek to saved position")
                    
                    // Resume server time sync even if seek failed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        os_log(.debug, log: self.logger, "▶️ Resuming server time sync after failed recovery")
                    }
                }
                
                // DON'T clear saved position here - keep it for potential lock screen recovery
                os_log(.info, log: self.logger, "ℹ️ App open recovery complete - keeping position for potential lock screen recovery")
                DebugLogManager.shared.logInfo("ℹ️ App open recovery complete - keeping position for potential lock screen recovery")
            }
        }
    }
    
    private func tryDirectPreferenceMethod(completion: @escaping (Bool) -> Void) {
        os_log(.info, log: logger, "🔧 Reading user's Material power-on resume setting")
        DebugLogManager.shared.logInfo("🔧 Reading user's Material power-on resume setting")
        
        let currentPosition = audioManager.getCurrentTime()
        let playerID = settings.playerMACAddress
        
        os_log(.info, log: logger, "📍 Current position: %.2f seconds, Player: %{public}s", currentPosition, playerID)
        DebugLogManager.shared.logInfo("📍 Current position: \(String(format: "%.2f", currentPosition))s, Player: \(playerID)")
        
        // CRITICAL CHECK: If position is 0, we still want to proceed for user preference setting
        if currentPosition <= 0.0 {
            os_log(.error, log: logger, "⚠️ Current position is %.2f - this might indicate an issue", currentPosition)
            DebugLogManager.shared.logWarning("⚠️ Current position is \(String(format: "%.2f", currentPosition)) - checking if this is expected")
        }
        
        // First, read the user's power-on resume preference from Material
        let getPrefCommand = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, ["playerpref", "powerOnResume", "?"]]
        ] as [String : Any]
        
        sendJSONRPCCommandDirect(getPrefCommand) { [weak self] result in
            guard let self = self else { 
                completion(false)
                return 
            }
            
            // Parse the user's resume preference
            let resumePreference = self.parsePowerOnResumePreference(result)
            let shouldAutoResume = resumePreference.shouldAutoResume
            let resumeFromStart = resumePreference.shouldResumeFromStart
            
            os_log(.info, log: self.logger, "📱 User's Material setting: %{public}s (auto-resume: %{public}s)", 
                   resumePreference.rawValue, shouldAutoResume ? "YES" : "NO")
            
            DebugLogManager.shared.logInfo("📱 Material Setting: \(resumePreference.rawValue) (auto-resume: \(shouldAutoResume ? "YES" : "NO"))")
            
            // INSIGHT: We cannot manually set playingAtPowerOff/positionAtDisconnect via JSON-RPC
            // These are server-internal preferences set automatically during disconnect
            // Instead, we need to ensure the server SEES us as playing when we disconnect
            
            os_log(.info, log: self.logger, "🎯 User wants auto-resume: %{public}s - skipping manual preference setting", shouldAutoResume ? "YES" : "NO")
            DebugLogManager.shared.logInfo("🎯 User wants auto-resume: \(shouldAutoResume ? "YES" : "NO") - server will handle this automatically")
            
            // The real strategy: Use silent resume to ensure server sees us as PLAYING during disconnect
            // This will make server's persistPlaybackStateForPowerOff save playingAtPowerOff=true
            os_log(.info, log: self.logger, "✅ User preference understood - proceeding with server-compatible method")
            DebugLogManager.shared.logInfo("✅ User preference understood - proceeding with server-compatible method")
            completion(true)
        }
    }
    
    // Helper method to parse Material power-on resume preference
    private func parsePowerOnResumePreference(_ result: [String: Any]) -> PowerOnResumePreference {
        // Look for the preference value in the result
        if let resultData = result["result"] as? [String: Any] {
            os_log(.info, log: logger, "🔍 PARSING: Full result data: %{public}s", String(describing: resultData))
            DebugLogManager.shared.logInfo("🔍 PARSING: Full result data: \(String(describing: resultData))")
            
            // Try different possible keys that the server might return
            let possibleKeys = ["_p2", "_powerOnResume", "powerOnResume", "_pref"]
            
            for key in possibleKeys {
                if let prefValue = resultData[key] as? String {
                    os_log(.info, log: logger, "🔍 FOUND preference at key '%{public}s': %{public}s", key, prefValue)
                    DebugLogManager.shared.logInfo("🔍 FOUND preference at key '\(key)': \(prefValue)")
                    
                    // Handle full format like "PauseOff-PlayOn" or shortened format like "resumePlayOn"
                    if prefValue.contains("-") {
                        // Full format: extract the "On" part after the dash
                        let components = prefValue.components(separatedBy: "-")
                        if components.count == 2 {
                            let onPart = components[1]
                            os_log(.info, log: logger, "🔍 EXTRACTED 'On' part: %{public}s", onPart)
                            return PowerOnResumePreference(rawValue: onPart)
                        }
                    } else {
                        // Shortened format: use as-is
                        return PowerOnResumePreference(rawValue: prefValue)
                    }
                }
            }
        }
        
        os_log(.info, log: logger, "🔍 NO preference found - defaulting to noResume")
        DebugLogManager.shared.logWarning("🔍 NO preference found - defaulting to noResume")
        // Default to no resume if we can't read the preference
        return .noResume
    }
    
    private func performSilentResumeMethod() {
        os_log(.info, log: logger, "🔇 Silent resume strategy - paused by lock screen + backgrounded")
        os_log(.info, log: logger, "⚠️ Server only saves position when isPlaying(1) = true during disconnect")
        os_log(.info, log: logger, "🎯 Solution: Silent resume → set isPlaying(1) → disconnect")
        
        // Step 1: Store current volume and mute audio
        let originalVolume = audioManager.getVolume()
        audioManager.setVolume(0.0)
        
        // Step 2: Send resume command silently to set server isPlaying(1) flag
        os_log(.info, log: logger, "🔇 Resuming silently to set server isPlaying(1)")
        commandHandler.handleUnpauseCommand()
        
        // Step 3: Reset lock screen pause flag so STMt heartbeats resume
        commandHandler.isPausedByLockScreen = false
        os_log(.info, log: logger, "🔇 Reset isPausedByLockScreen - STMt heartbeats will resume")
        
        // Step 4: Wait for STMt messages to be sent to server, then disconnect
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Restore original volume
            self.audioManager.setVolume(originalVolume)
            
            os_log(.info, log: self.logger, "🔌 Disconnecting while server thinks we're playing")
            os_log(.info, log: self.logger, "📍 Server will save playingAtPowerOff=true and positionAtDisconnect")
            os_log(.info, log: self.logger, "🔄 Lock screen resume will trigger server's resumeOnPower() logic")
            
            // Clean disconnect to trigger server's persistPlaybackStateForPowerOff
            self.disconnect()
        }
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
        // Legacy sleep status removed - modern recovery uses local position saving
        os_log(.debug, log: logger, "💤 App will sleep - relying on position recovery system")
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
            self.ensureRadioMetadataRefreshIsRunning()
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
        
        // CRITICAL: Mark lock screen play recovery early to prevent double recovery
        if command.lowercased() == "play" {
            isLockScreenPlayRecovery = true
            os_log(.info, log: logger, "🔒 Lock screen play - marked for position recovery")
        }
        
        // SIMPLE STRATEGY: For PLAY commands after disconnect, reconnect and seek to saved position
        if command.lowercased() == "play" && !connectionManager.connectionState.isConnected {
            os_log(.info, log: logger, "🔄 PLAY after disconnect - using simple position recovery")
            DebugLogManager.shared.logInfo("🔄 PLAY after disconnect - using simple position recovery")
            
            // CRITICAL: Ensure audio session is active for background playback
            audioManager.activateAudioSession()
            
            // Reconnect and handle position recovery manually
            connect()
            
            // Monitor reconnection and apply saved position
            monitorReconnectionForSimplePositionRecovery()
            return
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
        DebugLogManager.shared.logInfo("👀 Monitoring reconnection for simple position recovery")
        
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
                DebugLogManager.shared.logInfo("✅ Reconnected - applying simple position recovery")
                timer.invalidate()
                
                // Wait a moment for connection to stabilize, then seek and play
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.performSimplePositionRecovery()
                }
                
            } else if attempts >= maxAttempts {
                os_log(.error, log: self.logger, "❌ Reconnection timeout for position recovery")
                DebugLogManager.shared.logError("❌ Reconnection timeout for position recovery")
                timer.invalidate()
            }
        }
    }
    
    private func performSimplePositionRecovery() {
        // DEBUG: Log the current state of saved position variables
        os_log(.info, log: logger, "🔍 Lock screen recovery check - shouldResumeOnPlay: %{public}s, savedPosition: %.2f, timestamp: %{public}s", 
               shouldResumeOnPlay ? "YES" : "NO", savedPosition, 
               savedPositionTimestamp?.description ?? "nil")
        DebugLogManager.shared.logInfo("🔍 Lock screen recovery check - shouldResumeOnPlay: \(shouldResumeOnPlay ? "YES" : "NO"), savedPosition: \(String(format: "%.2f", savedPosition)), timestamp: \(savedPositionTimestamp?.description ?? "nil")")
        
        // Check if we have a saved position to recover
        guard shouldResumeOnPlay,
              let timestamp = savedPositionTimestamp,
              savedPosition > 0.1 else {
            os_log(.info, log: logger, "ℹ️ No saved position to recover - playing from current position")
            DebugLogManager.shared.logInfo("ℹ️ No saved position to recover - playing from current position")
            sendJSONRPCCommand("play")
            return
        }
        
        // Check if the saved position is recent (within 10 minutes)
        let timeSinceSave = Date().timeIntervalSince(timestamp)
        guard timeSinceSave < 600 else {
            os_log(.info, log: logger, "⚠️ Saved position too old (%.0f seconds) - playing from current position", timeSinceSave)
            DebugLogManager.shared.logWarning("⚠️ Saved position too old (\(Int(timeSinceSave)) seconds) - playing from current position")
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
            DebugLogManager.shared.logError("🚨 REJECTING stale position \(String(format: "%.2f", savedPosition)) - server shows \(String(format: "%.2f", currentServerTime)) (diff: \(String(format: "%.2f", timeDifference)))")
            clearSavedPosition()
            
            // CRITICAL: Use current server position instead of starting from 0
            os_log(.info, log: logger, "🎯 Using current server position: %.2f seconds instead of stale position", currentServerTime)
            DebugLogManager.shared.logInfo("🎯 Using current server position: \(String(format: "%.2f", currentServerTime)) seconds instead of stale position")
            
            // Recover to current server position instead of saved position
            savedPosition = currentServerTime
            // Continue with normal recovery logic using current server position
        }
        
        os_log(.info, log: logger, "🎯 Recovering to saved position: %.2f seconds", savedPosition)
        DebugLogManager.shared.logInfo("🎯 Recovering to saved position: \(String(format: "%.2f", savedPosition)) seconds")
        
        // Lock screen recovery: play → seek → play (fast sequence to minimize audio blip)
        os_log(.info, log: logger, "🔄 Lock screen: play → seek → play sequence (fast)")
        DebugLogManager.shared.logInfo("🔄 Lock screen: play → seek → play sequence (fast)")
        
        // CRITICAL: Pause server time sync during lock screen recovery too
        os_log(.debug, log: logger, "⏸️ Pausing server time sync during lock screen recovery")
        
        sendJSONRPCCommand("play")
        
        // Wait briefly for playback to start, then seek to saved position
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            os_log(.info, log: self.logger, "🎯 Now seeking to saved position: %.2f seconds", self.savedPosition)
            DebugLogManager.shared.logInfo("🎯 Now seeking to saved position: \(String(format: "%.2f", self.savedPosition)) seconds")
            
            self.sendSeekCommand(to: self.savedPosition) { [weak self] seekSuccess in
                guard let self = self else { return }
                
                if seekSuccess {
                    os_log(.info, log: self.logger, "✅ Lock screen: Seek successful - continuing playback")
                    DebugLogManager.shared.logInfo("✅ Lock screen: Seek successful - continuing playback")
                    
                    // For lock screen recovery, continue playing after seek
                    // No additional play command needed - we're already playing
                } else {
                    os_log(.error, log: self.logger, "❌ Lock screen: Failed to seek to saved position")
                    DebugLogManager.shared.logError("❌ Lock screen: Failed to seek to saved position")
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
                DebugLogManager.shared.logInfo("🎵 Lock screen recovery complete")
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
            DebugLogManager.shared.logInfo("✅ Material UI refreshed after recovery")
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
        DebugLogManager.shared.logInfo("🌐 Sending JSON-RPC: \(String(describing: jsonRPC))")
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonRPC) else {
            os_log(.error, log: logger, "❌ Failed to create JSON-RPC command")
            DebugLogManager.shared.logError("❌ Failed to create JSON-RPC command")
            completion([:])
            return
        }
        
        let urlString = "\(settings.webURL)jsonrpc.js"
        os_log(.info, log: logger, "🌐 JSON-RPC URL: %{public}s", urlString)
        DebugLogManager.shared.logInfo("🌐 JSON-RPC URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            os_log(.error, log: logger, "❌ Invalid JSON-RPC URL: %{public}s", urlString)
            DebugLogManager.shared.logError("❌ Invalid JSON-RPC URL: \(urlString)")
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
                DebugLogManager.shared.logError("❌ JSON-RPC request failed: \(error.localizedDescription)")
                completion([:])
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                os_log(.info, log: self.logger, "🌐 JSON-RPC response status: %d", httpResponse.statusCode)
                DebugLogManager.shared.logInfo("🌐 JSON-RPC response status: \(httpResponse.statusCode)")
            }
            
            guard let data = data else {
                os_log(.error, log: self.logger, "❌ No data received from JSON-RPC request")
                DebugLogManager.shared.logError("❌ No data received from JSON-RPC request")
                completion([:])
                return
            }
            
            do {
                if let jsonResult = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    os_log(.info, log: self.logger, "✅ JSON-RPC response: %{public}s", String(describing: jsonResult))
                    DebugLogManager.shared.logInfo("✅ JSON-RPC response: \(String(describing: jsonResult))")
                    completion(jsonResult)
                } else {
                    os_log(.error, log: self.logger, "❌ Invalid JSON-RPC response format")
                    DebugLogManager.shared.logError("❌ Invalid JSON-RPC response format")
                    completion([:])
                }
            } catch {
                os_log(.error, log: self.logger, "❌ Failed to parse JSON-RPC response: %{public}s", error.localizedDescription)
                DebugLogManager.shared.logError("❌ Failed to parse JSON-RPC response: \(error.localizedDescription)")
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
        
        // ENHANCED: Request additional tags for radio/plugin artwork support
        let jsonRPC = [
            "id": 1,
            "method": "slim.request",
            "params": [
                playerID,
                [
                    "status", "-", "1",
                    // ENHANCED: Added artwork_url (u), coverid (c), icon (i), and image tags
                    "tags:u,a,A,l,t,d,e,s,o,r,c,g,p,i,q,y,j,J,K,N,S,w,x,C,G,R,T,I,D,U,F,L,f,n,m,b,v,h,k,z,url,remote_title,bitrate"
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
    
    // Replace the parseTrackMetadata method in SlimProtoCoordinator.swift
    private func parseTrackMetadata(data: Data) {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let loop = result["playlist_loop"] as? [[String: Any]],
               let firstTrack = loop.first {
                
                // Metadata parsing - debug logging removed to reduce spam
                
                // ENHANCED: Handle radio stream metadata with better field priority
                var trackTitle = "LMS Stream"
                var trackArtist = "Unknown Artist"
                var isRadioStream = false
                
                // Check if this is a radio stream by looking for indicators
                if let url = firstTrack["url"] as? String {
                    isRadioStream = url.contains("stream") || url.contains("radio") || url.contains("live") ||
                                   url.contains(".pls") || url.contains(".m3u") || url.hasPrefix("http")
                }
                
                if isRadioStream {
                    
                    // For radio streams, prioritize fields that contain current song info
                    // Priority 1: Check 'title' field first (often contains current song)
                    if let title = firstTrack["title"] as? String, !title.isEmpty &&
                       !title.contains("(pls)") && !title.contains("FM") && !title.contains("Radio") {
                        
                        // Parse "Artist - Title" format if present
                        let components = title.components(separatedBy: " - ")
                        if components.count >= 2 {
                            trackArtist = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            trackTitle = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                            // Parsed from title field
                        } else {
                            trackTitle = title
                            // FIXED: Also check for separate artist field when title doesn't contain " - "
                            if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                                trackArtist = artist
                                // Using title + separate artist
                            } else {
                                // Using title field only
                            }
                        }
                    }
                    // Priority 2: Check 'track' field (sometimes contains current song)
                    else if let track = firstTrack["track"] as? String, !track.isEmpty &&
                            !track.contains("(pls)") && !track.contains("FM") && !track.contains("Radio") {
                        
                        let components = track.components(separatedBy: " - ")
                        if components.count >= 2 {
                            trackArtist = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            trackTitle = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                            // Parsed from track field
                        } else {
                            trackTitle = track
                            // FIXED: Also check for separate artist field
                            if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                                trackArtist = artist
                                // Using track + separate artist
                            } else {
                                // Using track field only
                            }
                        }
                    }
                    // Priority 3: Try remote_title but filter out station names
                    else if let remoteTitle = firstTrack["remote_title"] as? String, !remoteTitle.isEmpty &&
                            !remoteTitle.contains("(pls)") && !remoteTitle.contains("FM") && !remoteTitle.contains("Radio") {
                        
                        let components = remoteTitle.components(separatedBy: " - ")
                        if components.count >= 2 {
                            trackArtist = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            trackTitle = components.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                            // Parsed from remote_title
                        } else {
                            trackTitle = remoteTitle
                            // FIXED: Also check for separate artist field
                            if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                                trackArtist = artist
                                // Using remote_title + separate artist
                            } else {
                                // Using remote_title only
                            }
                        }
                    }
                    // Priority 4: Use separate title and artist fields
                    else {
                        if let title = firstTrack["title"] as? String, !title.isEmpty {
                            trackTitle = title
                        } else if let track = firstTrack["track"] as? String, !track.isEmpty {
                            trackTitle = track
                        }
                        
                        if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                            trackArtist = artist
                        }
                        
                        // Using fallback separate fields
                    }
                    
                    // REMOVED: The section that looks for station names and overwrites good data
                    // We already have the correct title and artist, don't second-guess it
                } else {
                    // Non-radio stream - use original logic
                    trackTitle = firstTrack["title"] as? String ??
                               firstTrack["track"] as? String ?? "LMS Stream"
                    
                    if let artist = firstTrack["artist"] as? String, !artist.isEmpty {
                        trackArtist = artist
                    } else if let albumArtist = firstTrack["albumartist"] as? String, !albumArtist.isEmpty {
                        trackArtist = albumArtist
                    } else if let contributors = firstTrack["contributors"] as? [[String: Any]] {
                        for contributor in contributors {
                            if let role = contributor["role"] as? String,
                               let name = contributor["name"] as? String,
                               role.lowercased().contains("artist") {
                                trackArtist = name
                                break
                            }
                        }
                    }
                    // Non-radio metadata
                }
                
                let trackAlbum = firstTrack["album"] as? String ?? (isRadioStream ? firstTrack["remote_title"] as? String ?? "Internet Radio" : "Lyrion Music Server")
                // CRITICAL FIX: Only update duration if server explicitly provides it (Material skin approach)
                let serverDuration = firstTrack["duration"] as? Double
                
                // ENHANCED: Multi-source artwork URL detection (existing code remains the same)
                var artworkURL: String? = nil
                
                // Priority 1: Check for remote artwork URL (radio stations, plugins like Radio Paradise, TuneIn, etc.)
                if let remoteArtworkURL = firstTrack["artwork_url"] as? String, !remoteArtworkURL.isEmpty {
                    // Handle both relative and absolute URLs
                    if remoteArtworkURL.hasPrefix("http://") || remoteArtworkURL.hasPrefix("https://") {
                        // Absolute URL - use as-is (common for Radio Paradise, TuneIn, etc.)
                        artworkURL = remoteArtworkURL
                    } else if remoteArtworkURL.hasPrefix("/") {
                        // Relative URL - prepend server address
                        let webPort = settings.activeServerWebPort
                        let host = settings.activeServerHost
                        artworkURL = "http://\(host):\(webPort)\(remoteArtworkURL)"
                    }
                }
                
                // Priority 2: Check for coverid (local music library)
                if artworkURL == nil, let coverid = firstTrack["coverid"] as? String, !coverid.isEmpty, coverid != "0" {
                    let webPort = settings.activeServerWebPort
                    let host = settings.activeServerHost
                    artworkURL = "http://\(host):\(webPort)/music/\(coverid)/cover.jpg"
                }
                
                // Priority 3: Fallback to track ID (legacy method for local tracks)
                if artworkURL == nil, let trackID = firstTrack["id"] as? Int {
                    let webPort = settings.activeServerWebPort
                    let host = settings.activeServerHost
                    artworkURL = "http://\(host):\(webPort)/music/\(trackID)/cover.jpg"
                }
                
                // Priority 4: Check for plugin-specific icon/image fields
                if artworkURL == nil {
                    // Some plugins use 'icon' field
                    if let iconURL = firstTrack["icon"] as? String, !iconURL.isEmpty {
                        if iconURL.hasPrefix("http://") || iconURL.hasPrefix("https://") {
                            artworkURL = iconURL
                        } else if iconURL.hasPrefix("/") {
                            let webPort = settings.activeServerWebPort
                            let host = settings.activeServerHost
                            artworkURL = "http://\(host):\(webPort)\(iconURL)"
                        }
                    }
                    // Some plugins use 'image' field
                    else if let imageURL = firstTrack["image"] as? String, !imageURL.isEmpty {
                        if imageURL.hasPrefix("http://") || imageURL.hasPrefix("https://") {
                            artworkURL = imageURL
                        } else if imageURL.hasPrefix("/") {
                            let webPort = settings.activeServerWebPort
                            let host = settings.activeServerHost
                            artworkURL = "http://\(host):\(webPort)\(imageURL)"
                        }
                    }
                }
                
                // Log final metadata result
                let sourceType = determineSourceType(from: firstTrack)
                os_log(.info, log: logger, "🎵 %{public}s: '%{public}s' by %{public}s%{public}s",
                       sourceType, trackTitle, trackArtist, artworkURL != nil ? " [artwork]" : "")
                
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
