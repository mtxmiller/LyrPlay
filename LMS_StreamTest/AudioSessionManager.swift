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
        setupInitialAudioSession()
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
    
    // MARK: - Audio Session Setup
    private func setupInitialAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: [.allowBluetooth, .allowAirPlay]
            )
            try audioSession.setActive(true)
            
            os_log(.info, log: logger, "✅ Initial audio session configured")
        } catch {
            os_log(.error, log: logger, "❌ Failed to setup initial audio session: %{public}s", error.localizedDescription)
        }
    }
    
    // MARK: - Format-Specific Audio Session Configuration
    func setupForLosslessAudio() {
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
            
            // CRITICAL FIX: Don't force activation - let StreamingKit handle timing
            // if !audioSession.isOtherAudioPlaying {
            //     try audioSession.setActive(true)  // REMOVED - this conflicts with StreamingKit
            //     os_log(.info, log: logger, "🔧 Activated audio session")
            // }
            
            os_log(.info, log: logger, "✅ Lossless audio session configured (StreamingKit handles activation)")
        } catch {
            os_log(.error, log: logger, "⚠️ Audio session setup warning: %{public}s (continuing anyway)", error.localizedDescription)
        }
    }
    
    func setupForCompressedAudio() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
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
                try audioSession.setPreferredSampleRate(44100.0)
                os_log(.info, log: logger, "🔧 Updated sample rate to 44100 Hz")
            }
            
            // Only set buffer duration if it's different
            if audioSession.preferredIOBufferDuration != 0.02 {
                try audioSession.setPreferredIOBufferDuration(0.02)
                os_log(.info, log: logger, "🔧 Updated buffer duration to 20ms")
            }
            
            // CRITICAL FIX: Don't force activation - let StreamingKit handle timing
            // if !audioSession.isOtherAudioPlaying {
            //     try audioSession.setActive(true)  // REMOVED - this conflicts with StreamingKit
            //     os_log(.info, log: logger, "🔧 Activated audio session")
            // }
            
            os_log(.info, log: logger, "✅ Compressed audio session configured (StreamingKit handles activation)")
        } catch {
            os_log(.error, log: logger, "⚠️ Audio session setup warning: %{public}s (continuing anyway)", error.localizedDescription)
        }
    }
    
    // MARK: - Enhanced Audio Session Control
    func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            os_log(.info, log: logger, "✅ Audio session activated")
        } catch {
            os_log(.error, log: logger, "❌ Failed to activate audio session: %{public}s", error.localizedDescription)
        }
    }
    
    func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            os_log(.info, log: logger, "✅ Audio session deactivated")
        } catch {
            os_log(.error, log: logger, "❌ Failed to deactivate audio session: %{public}s", error.localizedDescription)
        }
    }
    
    // MARK: - Interruption Recovery
    func reconfigureAfterInterruption() {
        os_log(.info, log: logger, "🔄 Reconfiguring audio session after interruption")
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            // Reactivate the audio session
            try audioSession.setActive(true)
            
            // Verify our category and options are still correct
            if audioSession.category != .playback {
                try audioSession.setCategory(
                    .playback,
                    mode: .default,
                    options: [.allowBluetooth, .allowAirPlay, .allowBluetoothA2DP]
                )
                os_log(.info, log: logger, "🔧 Restored audio session category after interruption")
            }
            
            os_log(.info, log: logger, "✅ Audio session reconfigured successfully")
        } catch {
            os_log(.error, log: logger, "❌ Failed to reconfigure audio session: %{public}s", error.localizedDescription)
        }
    }
    
    func reconfigureAfterMediaServicesReset() {
        os_log(.info, log: logger, "🔄 Reconfiguring audio session after media services reset")
        
        // Complete reconfiguration is needed after media services reset
        setupInitialAudioSession()
        
        // Apply format-specific settings if we had them
        // This should be called by the AudioManager based on current format
        os_log(.info, log: logger, "✅ Audio session fully reconfigured after media services reset")
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
