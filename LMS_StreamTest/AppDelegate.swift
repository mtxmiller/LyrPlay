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
        os_log(.info, log: logger, "Configuring scene session")
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
