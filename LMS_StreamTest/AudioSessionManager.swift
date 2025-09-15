// File: AudioSessionManager.swift
// Enhanced with interruption handling integration
import Foundation
import AVFoundation
import UIKit
import os.log

protocol AudioSessionManagerDelegate: AnyObject {
    func audioSessionDidEnterBackground()
    func audioSessionDidEnterForeground()
    func audioSessionWasInterrupted(shouldPause: Bool)
    func audioSessionInterruptionEnded(shouldResume: Bool)
    func audioSessionRouteChanged(shouldPause: Bool)
}

class AudioSessionManager: ObservableObject {
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioSessionManager")
    private let settings = SettingsManager.shared
    
    // MARK: - Background Management
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    // MARK: - Interruption Integration
    var interruptionManager: InterruptionManager?
    
    // MARK: - Delegation
    weak var delegate: AudioSessionManagerDelegate?
    
    // MARK: - Initialization
    init() {
        //setupInitialAudioSession()
        setupBackgroundObservers()
        setupInterruptionManager()
        os_log(.info, log: logger, "Enhanced AudioSessionManager initialized")
    }
    
    // MARK: - Interruption Manager Setup
    private func setupInterruptionManager() {
        interruptionManager = InterruptionManager()
        interruptionManager?.delegate = self
        os_log(.info, log: logger, "✅ Interruption manager integrated")
    }
    
    // MARK: - Audio Session Setup (DISABLED)
    private func setupInitialAudioSession() {
        // DISABLED: AudioPlayer handles initial session setup with BASS_IOS_SESSION_DISABLE
        os_log(.info, log: logger, "✅ Initial audio session handled by AudioPlayer (BASS_IOS_SESSION_DISABLE)")
    }
    
    // MARK: - Format-Specific Audio Session Configuration (DISABLED)
    func setupForLosslessAudio() {
        // DISABLED: AudioPlayer handles all session configuration with BASS_IOS_SESSION_DISABLE
        os_log(.info, log: logger, "✅ Lossless audio - session handled by AudioPlayer (BASS_IOS_SESSION_DISABLE)")
    }
    
    func setupForCompressedAudio() {
        // DISABLED: AudioPlayer handles all session configuration with BASS_IOS_SESSION_DISABLE
        os_log(.info, log: logger, "✅ Compressed audio - session handled by AudioPlayer (BASS_IOS_SESSION_DISABLE)")
    }
    
    // MARK: - Enhanced Audio Session Control (DISABLED)
    func activateAudioSession() {
        // DISABLED: BASS handles activation with BASS_IOS_SESSION_DISABLE
        os_log(.info, log: logger, "✅ Audio session activation handled by BASS")
    }
    
    func deactivateAudioSession() {
        // DISABLED: BASS handles deactivation with BASS_IOS_SESSION_DISABLE  
        os_log(.info, log: logger, "✅ Audio session deactivation handled by BASS")
    }
    
    // MARK: - Interruption Recovery (RESTORED)
    func reconfigureAfterInterruption() {
        // RESTORED: With BASS_IOS_SESSION_DISABLE, we need manual session management
        // Delegate to AudioPlayer's unified session management
        if let audioManager = delegate as? AudioManager {
            audioManager.activateAudioSession() // Now delegates to AudioPlayer.configureAudioSessionIfNeeded()
            os_log(.info, log: logger, "✅ Interruption recovery delegated to AudioPlayer")
        } else {
            os_log(.error, log: logger, "❌ Cannot access AudioManager for interruption recovery")
        }
    }
    
    // MARK: - CarPlay Audio Session Readiness (DISABLED)
    func maintainAudioSessionReadinessAfterCarPlayDisconnect() {
        os_log(.info, log: logger, "🚗 CarPlay disconnected - activating audio session for phone readiness")
        
        // Use AudioManager's session activation (same as lock screen recovery)
        // This ensures consistent session handling across all recovery scenarios
        if let delegate = delegate as? AudioManager {
            delegate.activateAudioSession()
        }
        
        // Keep background task management active
        refreshBackgroundAudioCapabilities()
    }
    
    // MARK: - Background Audio Capabilities Management
    private func refreshBackgroundAudioCapabilities() {
        os_log(.info, log: logger, "🔄 Refreshing background audio capabilities")
        
        // Restart background task to maintain audio capabilities
        // This ensures iOS knows we're still an audio app even when backgrounded
        stopBackgroundTask()
        startBackgroundTask()
        
        os_log(.info, log: logger, "✅ Background audio capabilities refreshed")
    }
    
    func reconfigureAfterMediaServicesReset() {
        // DISABLED: BASS handles media services reset recovery with BASS_IOS_SESSION_DISABLE
        // AudioPlayer maintains session configuration, BASS handles reset recovery
        os_log(.info, log: logger, "✅ Media services reset handled by BASS (BASS_IOS_SESSION_DISABLE)")
    }
    
    // MARK: - Background Observers
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
        
        os_log(.info, log: logger, "✅ Background observers configured")
    }
    
    @objc private func appDidEnterBackground() {
        os_log(.info, log: logger, "📱 App entering background")
        startBackgroundTask()
        delegate?.audioSessionDidEnterBackground()
    }
    
    @objc private func appWillEnterForeground() {
        os_log(.info, log: logger, "📱 App entering foreground")
        stopBackgroundTask()
        delegate?.audioSessionDidEnterForeground()
        
        // Verify audio session is still properly configured
        verifyAudioSessionAfterForeground()
    }
    
    private func verifyAudioSessionAfterForeground() {
        let audioSession = AVAudioSession.sharedInstance()
        
        if audioSession.category != .playback {
            os_log(.error, log: logger, "⚠️ Audio session category changed while backgrounded - reconfiguring")
            reconfigureAfterInterruption()
        } else {
            os_log(.info, log: logger, "✅ Audio session maintained proper configuration in background")
        }
    }
    
    // MARK: - Background Task Management
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
            os_log(.info, log: logger, "🏁 Background task ended")
        }
    }
    
    // MARK: - Audio Session Information
    func getCurrentAudioRoute() -> String {
        return interruptionManager?.getCurrentAudioRoute() ?? "Unknown"
    }
    
    func isOtherAudioPlaying() -> Bool {
        return AVAudioSession.sharedInstance().isOtherAudioPlaying
    }
    
    func getPreferredSampleRate() -> Double {
        return AVAudioSession.sharedInstance().preferredSampleRate
    }
    
    func getPreferredIOBufferDuration() -> TimeInterval {
        return AVAudioSession.sharedInstance().preferredIOBufferDuration
    }
    
    func getInterruptionStatus() -> String {
        return interruptionManager?.getInterruptionStatus() ?? "Unknown"
    }
    
    // MARK: - Audio Session State
    func logCurrentAudioSessionState() {
        let audioSession = AVAudioSession.sharedInstance()
        
        os_log(.info, log: logger, "🔍 Current Audio Session State:")
        os_log(.info, log: logger, "  Category: %{public}s", audioSession.category.rawValue)
        os_log(.info, log: logger, "  Mode: %{public}s", audioSession.mode.rawValue)
        os_log(.info, log: logger, "  Options: %{public}s", String(describing: audioSession.categoryOptions))
        os_log(.info, log: logger, "  Sample Rate: %.0f Hz", audioSession.sampleRate)
        os_log(.info, log: logger, "  Preferred Sample Rate: %.0f Hz", audioSession.preferredSampleRate)
        os_log(.info, log: logger, "  IO Buffer Duration: %.3f ms", audioSession.ioBufferDuration * 1000)
        os_log(.info, log: logger, "  Preferred IO Buffer Duration: %.3f ms", audioSession.preferredIOBufferDuration * 1000)
        os_log(.info, log: logger, "  Other Audio Playing: %{public}s", audioSession.isOtherAudioPlaying ? "YES" : "NO")
        os_log(.info, log: logger, "  Current Route: %{public}s", getCurrentAudioRoute())
        os_log(.info, log: logger, "  Interruption Status: %{public}s", getInterruptionStatus())
    }
    
    // MARK: - Cleanup
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopBackgroundTask()
        os_log(.info, log: logger, "Enhanced AudioSessionManager deinitialized")
    }
}

// MARK: - InterruptionManagerDelegate
extension AudioSessionManager: InterruptionManagerDelegate {
    
    func interruptionDidBegin(type: InterruptionManager.InterruptionType, shouldPause: Bool) {
        os_log(.info, log: logger, "🚫 Interruption began: %{public}s (shouldPause: %{public}s)",
               type.description, shouldPause ? "YES" : "NO")
        
        if shouldPause {
            delegate?.audioSessionWasInterrupted(shouldPause: shouldPause)
        }
    }
    
    func interruptionDidEnd(type: InterruptionManager.InterruptionType, shouldResume: Bool) {
        os_log(.info, log: logger, "✅ Interruption ended: %{public}s (shouldResume: %{public}s)",
               type.description, shouldResume ? "YES" : "NO")
        
        // Reconfigure audio session after interruption
        reconfigureAfterInterruption()
        
        // Notify delegate about potential resume
        delegate?.audioSessionInterruptionEnded(shouldResume: shouldResume)
    }
    
    func routeDidChange(type: InterruptionManager.RouteChangeType, shouldPause: Bool) {
        os_log(.info, log: logger, "🔀 Route changed: %{public}s (shouldPause: %{public}s)",
               type.description, shouldPause ? "YES" : "NO")
        
        // GENTLE FIX: Maintain audio session readiness when CarPlay disconnects
        // This keeps the app ready to receive audio control without aggressively stealing it
        if type == .carPlayDisconnected {
            os_log(.info, log: logger, "🚗 CarPlay disconnected - maintaining audio session readiness")
            maintainAudioSessionReadinessAfterCarPlayDisconnect()
        }
        
        // Log the new route for debugging
        logCurrentAudioSessionState()
        
        // Notify delegate
        delegate?.audioSessionRouteChanged(shouldPause: shouldPause)
    }
    
    func audioSessionWasReset() {
        os_log(.error, log: logger, "🔄 Media services reset - reconfiguring everything")
        
        // Complete reconfiguration needed
        reconfigureAfterMediaServicesReset()
        
        // This is treated as an interruption that requires pause
        delegate?.audioSessionWasInterrupted(shouldPause: true)
    }
}
