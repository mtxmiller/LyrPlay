// File: AudioSessionManager.swift
// Audio session configuration and background task management
import Foundation
import AVFoundation
import UIKit
import os.log

protocol AudioSessionManagerDelegate: AnyObject {
    func audioSessionDidEnterBackground()
    func audioSessionDidEnterForeground()
}

class AudioSessionManager: ObservableObject {
    
    // MARK: - Configuration
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AudioSessionManager")
    private let settings = SettingsManager.shared
    
    // MARK: - Background Management
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    
    // MARK: - Delegation
    weak var delegate: AudioSessionManagerDelegate?
    
    // MARK: - Initialization
    init() {
        setupInitialAudioSession()
        setupBackgroundObservers()
        os_log(.info, log: logger, "AudioSessionManager initialized")
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
            
            if !audioSession.isOtherAudioPlaying {
                try audioSession.setActive(true)
                os_log(.info, log: logger, "🔧 Activated audio session")
            }
            
            os_log(.info, log: logger, "✅ Lossless audio session configured successfully")
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
            
            // Only activate if not already active
            if !audioSession.isOtherAudioPlaying {
                try audioSession.setActive(true)
                os_log(.info, log: logger, "🔧 Activated audio session")
            }
            
            os_log(.info, log: logger, "✅ Compressed audio session configured successfully")
        } catch {
            os_log(.error, log: logger, "⚠️ Audio session setup warning: %{public}s (continuing anyway)", error.localizedDescription)
        }
    }
    
    // MARK: - Audio Session Control
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
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        
        if let output = currentRoute.outputs.first {
            return output.portType.rawValue
        }
        
        return "Unknown"
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
    }
    
    // MARK: - Cleanup
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopBackgroundTask()
        os_log(.info, log: logger, "AudioSessionManager deinitialized")
    }
}
