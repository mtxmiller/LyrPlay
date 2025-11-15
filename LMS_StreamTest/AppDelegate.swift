import UIKit
import AVFoundation
import os.log

class AppDelegate: UIResponder, UIApplicationDelegate {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AppDelegate")
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        os_log(.info, log: logger, "App launching")
        
        // Load settings early
        let settings = SettingsManager.shared
        os_log(.info, log: logger, "Settings loaded - Configured: %{public}s", settings.isConfigured ? "YES" : "NO")
        
        // REMOVED: BASS will handle audio session configuration when initialized
        // Manual session setup in AppDelegate would conflict with BASS_CONFIG_IOS_SESSION
        os_log(.info, log: logger, "AVAudioSession will be managed by BASS framework")
        
        os_log(.info, log: logger, "App launch completed")
        return true
    }
    
    // MARK: UISceneSession Lifecycle
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        os_log(.info, log: logger, "🔷 SCENE ROUTING START")
        os_log(.info, log: logger, "  Session Role: %{public}s", String(describing: connectingSceneSession.role))
        os_log(.info, log: logger, "  Session Identifier: %{public}s", connectingSceneSession.persistentIdentifier)
        os_log(.info, log: logger, "  Connection Options: %{public}s", String(describing: options))

        // SwiftUI manages main app scene automatically - only route CarPlay
        if connectingSceneSession.role == .carTemplateApplication {
            os_log(.info, log: logger, "🚗 CARPLAY SCENE DETECTED")
            os_log(.info, log: logger, "  ✅ Returning CarPlay configuration")
            os_log(.info, log: logger, "  Delegate: LMS_StreamTest.CarPlaySceneDelegate")
            let config = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            os_log(.info, log: logger, "🔷 SCENE ROUTING COMPLETE - CarPlay config created")
            return config
        } else {
            // Main app scene - SwiftUI handles this automatically via @main App struct
            os_log(.info, log: logger, "📱 MAIN APP SCENE DETECTED - SwiftUI will handle automatically")
            // Return default config and let SwiftUI manage it
            return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        }
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        os_log(.info, log: logger, "🗑️ SCENE SESSIONS DISCARDED: %d sessions", sceneSessions.count)
        for session in sceneSessions {
            os_log(.info, log: logger, "  Discarded: %{public}s (role: %{public}s)",
                   session.persistentIdentifier, String(describing: session.role))
        }
    }
}
