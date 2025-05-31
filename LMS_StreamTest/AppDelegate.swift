import UIKit
import AVFoundation
import os.log

class AppDelegate: UIResponder, UIApplicationDelegate {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "AppDelegate")
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        os_log(.info, log: logger, "App launching")
        // Configure AVAudioSession for background playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            os_log(.info, log: logger, "AVAudioSession category set to playback")
            try AVAudioSession.sharedInstance().setActive(true)
            os_log(.info, log: logger, "AVAudioSession activated")
        } catch {
            os_log(.error, log: logger, "Audio session setup error: %{public}s", error.localizedDescription)
        }
        os_log(.info, log: logger, "App launch completed")
        return true
    }
    
    // MARK: UISceneSession Lifecycle
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        os_log(.info, log: logger, "Configuring scene session")
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
