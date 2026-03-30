import UIKit
import AVFoundation
import Intents
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
        
        // Request Siri authorization for voice commands
        INPreferences.requestSiriAuthorization { [weak self] status in
            os_log(.info, log: self?.logger ?? OSLog.default, "Siri authorization status: %d", status.rawValue)
        }

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

    // MARK: - Siri Intent Handling

    /// Return the handler for Siri intents when INIntentsSupported is declared in the main app
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        os_log(.info, log: logger, "🎤 SIRI: handlerFor intent: %{public}s", String(describing: type(of: intent)))
        if intent is INPlayMediaIntent {
            return SiriMediaHandler()
        }
        return nil
    }
}

// MARK: - Siri Media Intent Handler

/// Handles INPlayMediaIntent directly in the main app process.
/// Searches LMS via JSON-RPC and sends playback commands without needing
/// the Intents Extension or App Group for settings access.
class SiriMediaHandler: NSObject, INPlayMediaIntentHandling {

    private let logger = OSLog(subsystem: "com.lmsstream", category: "SiriMediaHandler")

    func resolveMediaItems(for intent: INPlayMediaIntent,
                          with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {

        let settings = SettingsManager.shared

        guard !settings.activeServerHost.isEmpty else {
            os_log(.error, log: logger, "Server not configured")
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        guard let searchTerm = intent.mediaSearch?.mediaName else {
            os_log(.error, log: logger, "No search term provided")
            completion([INPlayMediaMediaItemResolutionResult.unsupported()])
            return
        }

        os_log(.info, log: logger, "🎤 Searching for: %{public}s", searchTerm)

        // Search in priority order: Artists -> Albums -> Tracks -> Global
        searchLMS(query: searchTerm, type: "artists", resultKey: "artists_loop", idKey: "id", nameKey: "artist", prefix: "artist_id") { [weak self] result in
            if let item = result { completion([.success(with: item)]); return }

            self?.searchLMS(query: searchTerm, type: "albums", resultKey: "albums_loop", idKey: "id", nameKey: "album", prefix: "album_id") { result in
                if let item = result { completion([.success(with: item)]); return }

                self?.searchLMS(query: searchTerm, type: "tracks", resultKey: "tracks_loop", idKey: "id", nameKey: "title", prefix: "track_id") { result in
                    if let item = result { completion([.success(with: item)]); return }

                    os_log(.info, log: self?.logger ?? OSLog.default, "🎤 No results found for: %{public}s", searchTerm)
                    completion([INPlayMediaMediaItemResolutionResult.unsupported()])
                }
            }
        }
    }

    func handle(intent: INPlayMediaIntent,
               completion: @escaping (INPlayMediaIntentResponse) -> Void) {

        guard let mediaItem = intent.mediaItems?.first,
              let identifier = mediaItem.identifier,
              !identifier.isEmpty else {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let settings = SettingsManager.shared
        let playerMAC = settings.playerMACAddress

        os_log(.info, log: logger, "🎤 Sending playback command: %{public}s", identifier)

        let command: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerMAC, ["playlistcontrol", "cmd:load", identifier]]
        ]

        sendJSONRPC(command) { [weak self] response in
            if response != nil {
                os_log(.info, log: self?.logger ?? OSLog.default, "🎤 Playback started successfully")
                completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
            } else {
                os_log(.error, log: self?.logger ?? OSLog.default, "🎤 Playback command failed")
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            }
        }
    }

    // MARK: - LMS Search

    private func searchLMS(query: String, type: String, resultKey: String, idKey: String, nameKey: String, prefix: String,
                          completion: @escaping (INMediaItem?) -> Void) {
        let tags = type == "albums" ? "tags:ljy" : (type == "tracks" ? "tags:dlt" : "tags:s")
        let command: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", [type, 0, 10, tags, "search:\(query)"]]
        ]

        sendJSONRPC(command) { [weak self] response in
            guard let result = response?["result"] as? [String: Any],
                  let items = result[resultKey] as? [[String: Any]],
                  let first = items.first,
                  let itemId = first[idKey] as? Int,
                  let name = first[nameKey] as? String else {
                completion(nil)
                return
            }

            os_log(.info, log: self?.logger ?? OSLog.default, "🎤 Found %{public}s: %{public}s", type, name)
            completion(INMediaItem(identifier: "\(prefix):\(itemId)", title: name, type: .music, artwork: nil))
        }
    }

    private func sendJSONRPC(_ command: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        let settings = SettingsManager.shared
        let host = settings.activeServerHost
        let port = settings.activeServerWebPort

        guard let url = URL(string: "http://\(host):\(port)/jsonrpc.js") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 4.0

        if let authHeader = settings.generateAuthHeader() {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: command)
        } catch {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(json)
        }.resume()
    }
}
