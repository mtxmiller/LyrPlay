// File: AudioManager.swift (Refactored)
// Coordinator that manages all audio components while preserving the exact same public interface
import Foundation
import os.log

class AudioManager: NSObject, ObservableObject {
    
    // MARK: - Components
    private let audioPlayer: AudioPlayer
    private let audioSessionManager: AudioSessionManager
    private let nowPlayingManager: NowPlayingManager
    
    // MARK: - Time Update Throttling (ADD THIS LINE)
    private var lastTimeUpdateReport: Date = Date()
    private let minimumTimeUpdateInterval: TimeInterval = 2.0  // Max update every 2 seconds
    
    // NEW: Expose NowPlayingManager for coordinator access
    func getNowPlayingManager() -> NowPlayingManager {
        return nowPlayingManager
    }
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioManager")
    
    // MARK: - Public Interface (Preserved from Original)
    var onTrackEnded: (() -> Void)?
    var slimClient: SlimProtoCoordinator?  // Changed from weak to strong reference
    
    private var wasPlayingBeforeInterruption: Bool = false
    private var interruptionPosition: Double = 0.0
    
    // MARK: - Initialization
    override init() {
        self.audioPlayer = AudioPlayer()
        self.audioSessionManager = AudioSessionManager()
        self.nowPlayingManager = NowPlayingManager()
        
        super.init()
        
        setupDelegation()
        os_log(.info, log: logger, "✅ Refactored AudioManager initialized with modular architecture")
    }
    
    // MARK: - Component Integration
    private func setupDelegation() {
        // Connect AudioPlayer to AudioManager
        audioPlayer.delegate = self
        
        // Connect AudioSessionManager to AudioManager - ENHANCED
        audioSessionManager.delegate = self
        
        // Connect NowPlayingManager to AudioManager
        nowPlayingManager.delegate = self
        
        os_log(.info, log: logger, "✅ Component delegation configured with interruption handling")
    }
    
    // MARK: - Public Interface (Exact same as original AudioManager)
    
    // Stream playback methods
    func playStream(urlString: String) {
        audioPlayer.playStream(urlString: urlString)
    }
    
    func playStreamWithFormat(urlString: String, format: String) {
        // Configure audio session based on format
        configureAudioSessionForFormat(format)
        
        // Start playback
        audioPlayer.playStreamWithFormat(urlString: urlString, format: format)
    }
    
    func playStreamAtPosition(urlString: String, startTime: Double) {
        audioPlayer.playStreamAtPosition(urlString: urlString, startTime: startTime)
    }
    
    func playStreamAtPositionWithFormat(urlString: String, startTime: Double, format: String) {
        // Configure audio session based on format
        configureAudioSessionForFormat(format)
        
        // Start playback
        audioPlayer.playStreamAtPositionWithFormat(urlString: urlString, startTime: startTime, format: format)
    }
    
    // Playback control
    func play() {
        audioPlayer.play()
    }
    
    func pause() {
        audioPlayer.pause()
    }
    
    func stop() {
        audioPlayer.stop()
    }
    
    // State queries
    func getCurrentTime() -> Double {
        return audioPlayer.getCurrentTime()
    }
    
    func getDuration() -> Double {
        return audioPlayer.getDuration()
    }
    
    func getPosition() -> Float {
        return audioPlayer.getPosition()
    }
    
    func getPlayerState() -> String {
        return audioPlayer.getPlayerState()
    }
    
    func checkIfTrackEnded() -> Bool {
        // Delegate to player for consistency
        let currentTime = audioPlayer.getCurrentTime()
        let duration = audioPlayer.getDuration()
        
        if duration > 0 && currentTime >= duration - 0.5 {
            return true
        }
        
        return false
    }
    
    // MARK: - Volume Control
    func setVolume(_ volume: Float) {
        audioPlayer.setVolume(volume)
    }

    func getVolume() -> Float {
        return audioPlayer.getVolume()
    }
    
    // Metadata management
    func updateTrackMetadata(title: String, artist: String, album: String, artworkURL: String? = nil, duration: TimeInterval = 0.0) {
        // Update both the player and now playing manager
        audioPlayer.setMetadataDuration(duration)
        nowPlayingManager.updateTrackMetadata(
            title: title,
            artist: artist,
            album: album,
            artworkURL: artworkURL,
            duration: duration
        )
        
        os_log(.info, log: logger, "🎵 Updated track metadata: %{public}s - %{public}s", title, artist)
    }
    
    // MARK: - Private Audio Session Configuration
    private func configureAudioSessionForFormat(_ format: String) {
        switch format.uppercased() {
        case "ALAC", "FLAC":
            audioSessionManager.setupForLosslessAudio()
        case "AAC", "MP3":
            audioSessionManager.setupForCompressedAudio()
        default:
            audioSessionManager.setupForCompressedAudio()
        }
    }
    
    // MARK: - Lock Screen Integration (Preserved Interface)
    func setSlimClient(_ slimClient: SlimProtoCoordinator) {
        os_log(.info, log: logger, "🔗 AudioManager.setSlimClient called")
        self.slimClient = slimClient
        nowPlayingManager.setSlimClient(slimClient)
        os_log(.info, log: logger, "✅ SlimClient reference set for AudioManager and NowPlayingManager")
    }
    
    // MARK: - Cleanup
    deinit {
        os_log(.info, log: logger, "Refactored AudioManager deinitialized")
    }
}

// MARK: - AudioPlayerDelegate
extension AudioManager: AudioPlayerDelegate {
    
    func audioPlayerDidStartPlaying() {
        os_log(.info, log: logger, "▶️ Audio player started playing")
        
        // SIMPLIFIED: Just log the event, let the existing timer/update mechanisms handle position updates
        os_log(.debug, log: logger, "📍 Audio start event logged")
    }
    
    func audioPlayerDidPause() {
        os_log(.info, log: logger, "⏸️ Audio player paused")
        
        // Update now playing info
        let currentTime = audioPlayer.getCurrentTime()
        nowPlayingManager.updatePlaybackState(isPlaying: false, currentTime: currentTime)
    }
    
    func audioPlayerDidStop() {
        os_log(.info, log: logger, "⏹️ Audio player stopped")
        
        // Update now playing info
        nowPlayingManager.updatePlaybackState(isPlaying: false, currentTime: 0.0)
    }
    
    func audioPlayerDidReachEnd() {
        os_log(.info, log: logger, "🎵 Track ended - notifying coordinator")
        
        // Call the original callback
        onTrackEnded?()
    }
    
    func audioPlayerTimeDidUpdate(_ time: Double) {
        // REMOVED: All time update reporting and throttling
        // The server is the master - don't spam it with position updates
        
        // Only update now playing info locally, don't send to server
        let isPlaying = audioPlayer.getPlayerState() == "Playing"
        nowPlayingManager.updatePlaybackState(isPlaying: isPlaying, currentTime: time)
        
        // REMOVED: All the complicated throttling and server communication
        os_log(.debug, log: logger, "📍 Local time update only: %.2f", time)
    }

    
    func audioPlayerDidStall() {
        os_log(.error, log: logger, "⚠️ Audio player stalled")
        
        // Could add retry logic here in the future
    }
}

// MARK: - Interruption State Management (ADD THIS SECTION)
extension AudioManager {
    
    // MARK: - Interruption Handling Integration
    /// Called when audio session is interrupted (phone calls, etc.)
    func handleAudioInterruption(shouldPause: Bool) {
        guard shouldPause else { return }
        
        let currentState = getPlayerState()
        wasPlayingBeforeInterruption = (currentState == "Playing")
        // REMOVED: interruptionPosition = getCurrentTime() - don't track position
        
        os_log(.info, log: logger, "🚫 Audio interrupted - was playing: %{public}s",
               wasPlayingBeforeInterruption ? "YES" : "NO")
        
        if wasPlayingBeforeInterruption {
            audioPlayer.pause()
            // REMOVED: position tracking and server notification
            // Let the server handle position management
        }
    }
    
    /// Called when audio interruption ends
    func handleInterruptionEnded(shouldResume: Bool) {
        os_log(.info, log: logger, "✅ Interruption ended - should resume: %{public}s",
               shouldResume ? "YES" : "NO")
        
        if shouldResume && wasPlayingBeforeInterruption {
            // REMOVED: Position restoration - let server tell us where to go
            audioPlayer.play()
            
            // REMOVED: All server communication - let SlimProto handle it
            os_log(.info, log: logger, "▶️ Resumed playback - server maintains position")
        }
        
        wasPlayingBeforeInterruption = false
        // REMOVED: interruptionPosition = 0.0
    }
    
    /// Called when audio route changes (headphones, CarPlay, etc.)
    func handleRouteChange(shouldPause: Bool, routeType: String = "Unknown") {
        os_log(.info, log: logger, "🔀 Route change: %{public}s (shouldPause: %{public}s)",
               routeType, shouldPause ? "YES" : "NO")
        
        if shouldPause {
            let currentState = getPlayerState()
            let wasPlaying = (currentState == "Playing")
            let currentPosition = getCurrentTime()
            
            if wasPlaying {
                // Pause due to route change
                audioPlayer.pause()
                
                // Update now playing
                nowPlayingManager.updatePlaybackState(isPlaying: false, currentTime: currentPosition)
                
                // For CarPlay disconnect, notify server
                if routeType.contains("CarPlay") && routeType.contains("Disconnected") {
                    notifyServerOfCarPlayDisconnect(position: currentPosition)
                }
                
                os_log(.info, log: logger, "⏸️ Paused due to route change: %{public}s", routeType)
            }
        } else if routeType.contains("CarPlay") && routeType.contains("Connected") {
            // Special handling for CarPlay reconnection
            handleCarPlayReconnection()
        }
    }
    
    // MARK: - CarPlay Specific Handling
    private func handleCarPlayReconnection() {
        os_log(.info, log: logger, "🚗 CarPlay reconnected - checking for auto-resume")
        
        // Check if we should auto-resume (based on server state or last known state)
        // For now, we'll let the server tell us what to do
        if let slimClient = slimClient {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.notifyServerOfCarPlayReconnect()
            }
        }
    }
    
    // MARK: - Server Communication for Interruptions
    private func notifyServerOfInterruption(isPaused: Bool) {
        guard let slimClient = slimClient else { return }
        
        if isPaused {
            // Send pause command to server due to interruption
            slimClient.sendLockScreenCommand("pause")
            os_log(.info, log: logger, "📡 Notified server of interruption pause")
        } else {
            // Send resume command to server after interruption
            slimClient.sendLockScreenCommand("play")
            os_log(.info, log: logger, "📡 Notified server of interruption resume")
        }
    }
    
    private func notifyServerOfCarPlayDisconnect(position: Double) {
        guard let slimClient = slimClient else { return }
        
        // Send pause command specifically for CarPlay disconnect
        slimClient.sendLockScreenCommand("pause")
        os_log(.info, log: logger, "🚗 Notified server of CarPlay disconnect (position: %.2f)", position)
    }
    
    private func notifyServerOfCarPlayReconnect() {
        guard let slimClient = slimClient else { return }
        
        // Send resume command for CarPlay reconnect
        slimClient.sendLockScreenCommand("play")
        os_log(.info, log: logger, "🚗 Notified server of CarPlay reconnect")
    }
    
    // MARK: - Utility Methods
    private func getCurrentAudioFormat() -> String {
        // Try to determine current format based on player state
        // This is a simple heuristic - you might want to track this more explicitly
        let currentURL = getCurrentStreamURL()
        
        if currentURL.contains("format=aac") || currentURL.contains("type=aac") {
            return "AAC"
        } else if currentURL.contains("format=alac") || currentURL.contains("type=alac") {
            return "ALAC"
        } else if currentURL.contains("format=mp3") || currentURL.contains("type=mp3") {
            return "MP3"
        } else {
            return "AAC" // Default fallback
        }
    }
    
    private func getCurrentStreamURL() -> String {
        // This would need to be implemented based on how you track current stream URL
        // For now, return empty string as fallback
        return ""
    }
    
    // MARK: - Public Interruption Status
    func getInterruptionStatus() -> String {
        return audioSessionManager.getInterruptionStatus()
    }
    
    func isCurrentlyInterrupted() -> Bool {
        return audioSessionManager.getInterruptionStatus() != "Normal"
    }
}

// MARK: - AudioSessionManagerDelegate
extension AudioManager: AudioSessionManagerDelegate {
    
    func audioSessionDidEnterBackground() {
        os_log(.info, log: logger, "📱 Audio session entered background")
        // Existing background logic...
    }
    
    func audioSessionDidEnterForeground() {
        os_log(.info, log: logger, "📱 Audio session entered foreground")
        
        // Existing foreground logic...
        let currentTime = audioPlayer.getCurrentTime()
        let isPlaying = audioPlayer.getPlayerState() == "Playing"
        nowPlayingManager.updatePlaybackState(isPlaying: isPlaying, currentTime: currentTime)
    }
    
    // NEW: Handle interruptions
    func audioSessionWasInterrupted(shouldPause: Bool) {
        handleAudioInterruption(shouldPause: shouldPause)
    }
    
    // NEW: Handle interruption end
    func audioSessionInterruptionEnded(shouldResume: Bool) {
        handleInterruptionEnded(shouldResume: shouldResume)
    }
    
    // NEW: Handle route changes
    func audioSessionRouteChanged(shouldPause: Bool) {
        // Get the actual route change type from InterruptionManager
        let routeChangeDescription = audioSessionManager.interruptionManager?.lastRouteChange?.description ?? "Unknown"
        
        os_log(.info, log: logger, "🔀 Route change detected: %{public}s (shouldPause: %{public}s)",
               routeChangeDescription, shouldPause ? "YES" : "NO")
        
        if shouldPause {
            let currentState = getPlayerState()
            let wasPlaying = (currentState == "Playing")
            let currentPosition = getCurrentTime()
            
            if wasPlaying {
                // Pause due to route change
                audioPlayer.pause()
                
                // Update now playing
                nowPlayingManager.updatePlaybackState(isPlaying: false, currentTime: currentPosition)
                
                // Check for CarPlay disconnection using the proper route change type
                if routeChangeDescription == "CarPlay Disconnected" {
                    os_log(.info, log: logger, "🚗 CarPlay disconnection detected - notifying server")
                    notifyServerOfCarPlayDisconnect(position: currentPosition)
                } else {
                    os_log(.info, log: logger, "⏸️ Non-CarPlay route change pause: %{public}s", routeChangeDescription)
                }
                
                os_log(.info, log: logger, "⏸️ Paused due to route change: %{public}s", routeChangeDescription)
            }
        } else if routeChangeDescription == "CarPlay Connected" {
            // Special handling for CarPlay reconnection
            os_log(.info, log: logger, "🚗 CarPlay connection detected")
            handleCarPlayReconnection()
        }
    }
}

// MARK: - NowPlayingManagerDelegate
extension AudioManager: NowPlayingManagerDelegate {
    
    func nowPlayingDidReceivePlayCommand() {
        // NOTE: Not used - lock screen commands go directly to server
        os_log(.debug, log: logger, "🎵 Lock screen play command (unused)")
    }
    
    func nowPlayingDidReceivePauseCommand() {
        // NOTE: Not used - lock screen commands go directly to server
        os_log(.debug, log: logger, "⏸️ Lock screen pause command (unused)")
    }
    
    func nowPlayingDidReceiveNextTrackCommand() {
        // NOTE: Not used - lock screen commands go directly to server
        os_log(.debug, log: logger, "⏭️ Lock screen next track command (unused)")
    }
    
    func nowPlayingDidReceivePreviousTrackCommand() {
        // NOTE: Not used - lock screen commands go directly to server
        os_log(.debug, log: logger, "⏮️ Lock screen previous track command (unused)")
    }
}

// MARK: - Debug and Utility Methods
extension AudioManager {
    
    func logDetailedState() {
        os_log(.info, log: logger, "🔍 AudioManager State:")
        os_log(.info, log: logger, "  Player State: %{public}s", getPlayerState())
        os_log(.info, log: logger, "  Current Time: %.2f", getCurrentTime())
        os_log(.info, log: logger, "  Duration: %.2f", getDuration())
        os_log(.info, log: logger, "  Position: %.2f", getPosition())
        os_log(.info, log: logger, "  Track: %{public}s - %{public}s",
               nowPlayingManager.getCurrentTrackTitle(),
               nowPlayingManager.getCurrentArtist())
        
        // Log audio session state
        audioSessionManager.logCurrentAudioSessionState()
    }
    
    func getCurrentAudioRoute() -> String {
        return audioSessionManager.getCurrentAudioRoute()
    }
    
    func isOtherAudioPlaying() -> Bool {
        return audioSessionManager.isOtherAudioPlaying()
    }
}
// MARK: - Server Time Integration
extension AudioManager {
    /// Sets up server time synchronization for accurate lock screen timing
    /// This method should be called by SlimProtoCoordinator after connection
    func setupServerTimeIntegration(with synchronizer: ServerTimeSynchronizer) {
        // Connect the synchronizer to our NowPlayingManager
        nowPlayingManager.setServerTimeSynchronizer(synchronizer)
        nowPlayingManager.setAudioManager(self)
        
        os_log(.info, log: logger, "✅ Server time integration configured for AudioManager")
    }
    
    /// Gets time source information for debugging
    func getTimeSourceInfo() -> String {
        return nowPlayingManager.getTimeSourceInfo()
    }
    
    /// Gets server time synchronization status for debugging
    func getServerTimeStatus() -> String {
        return nowPlayingManager.getTimeSourceInfo()
    }
}
