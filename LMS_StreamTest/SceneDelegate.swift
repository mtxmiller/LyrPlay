//
//  SceneDelegate.swift
//  LMS_StreamTest
//
//  Scene delegate for main app window (required when using CarPlay with SwiftUI)
//

import UIKit
import SwiftUI
import os.log

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SceneDelegate")
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        os_log(.info, log: logger, "Main app scene connecting")

        // Create the SwiftUI view
        let contentView = ContentView()

        // Create the window and set the SwiftUI view as root
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: contentView)
        self.window = window
        window.makeKeyAndVisible()

        os_log(.info, log: logger, "Main app window configured")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        os_log(.info, log: logger, "Main app scene disconnected")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        os_log(.info, log: logger, "Main app scene became active")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        os_log(.info, log: logger, "Main app scene will resign active")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        os_log(.info, log: logger, "Main app scene entering foreground")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        os_log(.info, log: logger, "Main app scene entered background")
    }
}
