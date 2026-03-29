//
//  SceneDelegate.swift
//  LMS_StreamTest
//
//  Handles main window scene lifecycle and Siri intent delivery.
//  Registered programmatically via AppDelegate (same pattern as CarPlaySceneDelegate).
//

import UIKit
import Intents
import os.log

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    private let logger = OSLog(subsystem: "com.lmsstream", category: "SceneDelegate")

    /// Pending media identifier for cold launch (coordinator not ready yet)
    static var pendingMediaIdentifier: String?

    // MARK: - UIWindowSceneDelegate

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // Cold launch: check for Siri intent in connectionOptions
        for activity in connectionOptions.userActivities {
            os_log(.info, log: logger, "Cold launch: processing userActivity type=%{public}s",
                   activity.activityType)
            handleSiriActivity(activity)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        // Warm launch: Siri intent arrives here via NSUserActivity
        os_log(.info, log: logger, "Warm launch: continuing userActivity type=%{public}s",
               userActivity.activityType)
        handleSiriActivity(userActivity)
    }

    // MARK: - Siri Intent Handling

    private func handleSiriActivity(_ activity: NSUserActivity) {
        guard activity.activityType == "com.lmsstream.siri-play",
              let identifier = activity.userInfo?["identifier"] as? String,
              !identifier.isEmpty else {
            return
        }

        let title = activity.userInfo?["title"] as? String ?? "unknown"
        os_log(.info, log: logger, "Siri intent: identifier=%{public}s title=%{public}s",
               identifier, title)

        if let coordinator = AudioManager.shared.slimClient {
            os_log(.info, log: logger, "Coordinator ready - dispatching immediately")
            coordinator.playSiriMedia(identifier: identifier)
        } else {
            os_log(.info, log: logger, "Coordinator not ready - queuing pending intent")
            SceneDelegate.pendingMediaIdentifier = identifier
        }
    }

    // MARK: - Pending Intent Queue

    /// Called by SlimProtoCoordinator after connection is established.
    /// Returns and clears any pending Siri media identifier.
    static func consumePendingIntent() -> String? {
        let identifier = pendingMediaIdentifier
        pendingMediaIdentifier = nil
        return identifier
    }
}
