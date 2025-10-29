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
        setupBackgroundObservers()
        setupInterruptionManager()
        os_log(.info, log: logger, "Enhanced AudioSessionManager initialized")
    }
    
    // MARK: - Interruption Manager Setup
    private func setupInterruptionManager() {
        interruptionManager = InterruptionManager()
        os_log(.info, log: logger, "✅ Interruption manager stub initialized")
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
            os_log(.error, log: logger, "⚠️ Audio session category changed while backgrounded - BASS will handle reconfiguration")
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

