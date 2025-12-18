//
//  LMS_StreamTestApp.swift
//  LMS_StreamTest
//
//  Created by Eric Miller on 5/31/25.
//

import SwiftUI
import os.log

@main
struct LMS_StreamTestApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        let logger = OSLog(subsystem: "com.lmsstream", category: "App")
        os_log(.info, log: logger, "🚀 APP INITIALIZATION START")
        os_log(.info, log: logger, "  @main App struct created")
        os_log(.info, log: logger, "  @UIApplicationDelegateAdaptor configured")

        #if DEBUG || TESTFLIGHT
        // AUTO-UNLOCK ICON PACK FOR TESTFLIGHT/DEBUG BUILDS
        //PurchaseManager.shared.simulatePurchase(.iconPack)
        os_log(.debug, log: logger, "🧪 TESTFLIGHT: Icon Pack auto-unlocked for testing")
        #endif

        os_log(.info, log: logger, "🚀 APP INITIALIZATION COMPLETE")
    }

    var body: some Scene {
        let logger = OSLog(subsystem: "com.lmsstream", category: "App")
        os_log(.info, log: logger, "🏗️ APP BODY COMPUTED - Creating WindowGroup scene")

        return WindowGroup {
            ContentView()
        }
    }
}
