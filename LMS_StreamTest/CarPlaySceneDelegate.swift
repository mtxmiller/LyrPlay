import UIKit
import CarPlay
import os.log

@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "CarPlay")
    var interfaceController: CPInterfaceController?
    private var browseTemplate: CPListTemplate?

    @objc func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        os_log(.info, log: logger, "🚗 CARPLAY WILL CONNECT")
        os_log(.info, log: logger, "  Template Scene: %{public}s", String(describing: templateApplicationScene))
        os_log(.info, log: logger, "  Interface Controller: %{public}s", String(describing: interfaceController))
        os_log(.info, log: logger, "  Session: %{public}s", String(describing: templateApplicationScene.session))

        self.interfaceController = interfaceController
        os_log(.info, log: logger, "  ✅ Interface controller stored")

        // Create Browse list with CPListTemplate
        os_log(.info, log: logger, "  Creating Browse template...")

        // Create Resume Playback list item
        let resumeItem = CPListItem(
            text: "Resume Playback",
            detailText: "Start or resume from saved position",
            image: nil,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        resumeItem.handler = { [weak self] item, completion in
            guard let self = self else {
                completion()
                return
            }

            // Start playback
            self.handleResumePlayback()

            // Push Now Playing template onto navigation stack
            self.pushNowPlayingTemplate()

            completion()
        }

        // Create section with resume item
        let browseSection = CPListSection(items: [resumeItem])

        // Create Browse list template
        let browseTemplate = CPListTemplate(title: "LyrPlay", sections: [browseSection])
        self.browseTemplate = browseTemplate
        os_log(.info, log: logger, "  ✅ Browse template created")

        // Set Browse template as root (NOT in a tab bar - CPNowPlayingTemplate can't be in tab bar)
        os_log(.info, log: logger, "  Setting Browse template as root...")
        interfaceController.setRootTemplate(browseTemplate, animated: false) { success, error in
            if let error = error {
                os_log(.error, log: self.logger, "❌ FAILED to set root template: %{public}s", error.localizedDescription)
            } else if success {
                os_log(.info, log: self.logger, "  ✅ Browse template set successfully as root")
            } else {
                os_log(.error, log: self.logger, "❌ FAILED to set root template: success=false, no error")
            }
        }

        os_log(.info, log: logger, "🚗 CARPLAY CONNECTED SUCCESSFULLY")
    }

    @objc func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        os_log(.info, log: logger, "🚗 CARPLAY WILL DISCONNECT")
        os_log(.info, log: logger, "  Template Scene: %{public}s", String(describing: templateApplicationScene))
        os_log(.info, log: logger, "  Interface Controller: %{public}s", String(describing: interfaceController))

        self.interfaceController = nil
        os_log(.info, log: logger, "  ✅ Interface controller cleared")
        os_log(.info, log: logger, "🚗 CARPLAY DISCONNECTED")
    }

    // MARK: - Browse Actions

    private func handleResumePlayback() {
        os_log(.info, log: logger, "🚗 Resume playback requested from CarPlay Browse")

        // Ensure coordinator is initialized (may not be if only CarPlay scene is active)
        if AudioManager.shared.slimClient == nil {
            os_log(.info, log: logger, "⚠️ Coordinator not initialized - creating now...")
            initializeCoordinator()

            // CRITICAL FIX: Wait for connection before attempting recovery
            // coordinator.connect() is async - give it time to establish connection
            os_log(.info, log: logger, "⏳ Waiting 2s for coordinator to connect before recovery...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.attemptRecovery()
            }
        } else {
            // Coordinator already exists - attempt recovery immediately
            attemptRecovery()
        }
    }

    private func attemptRecovery() {
        guard let coordinator = AudioManager.shared.slimClient else {
            os_log(.error, log: logger, "❌ Cannot resume - no coordinator available after init")
            return
        }

        os_log(.info, log: logger, "✅ Attempting playlist recovery with playback enabled...")
        coordinator.performPlaylistRecovery(shouldPlay: true)
    }

    private func initializeCoordinator() {
        let settings = SettingsManager.shared
        let audioManager = AudioManager.shared

        os_log(.info, log: logger, "🔧 Initializing SlimProto coordinator from CarPlay...")

        // Create coordinator with audio manager
        let coordinator = SlimProtoCoordinator(audioManager: audioManager)

        // Connect coordinator to audio manager
        audioManager.setSlimClient(coordinator)

        // Configure with server settings
        coordinator.updateServerSettings(
            host: settings.activeServerHost,
            port: UInt16(settings.activeServerSlimProtoPort)
        )

        // Connect to server
        coordinator.connect()

        os_log(.info, log: logger, "✅ Coordinator initialized and connected")
    }

    private func pushNowPlayingTemplate() {
        guard let interfaceController = interfaceController else {
            os_log(.error, log: logger, "❌ Cannot push Now Playing - no interface controller")
            return
        }

        os_log(.info, log: logger, "📱 Pushing Now Playing template onto navigation stack...")

        let nowPlayingTemplate = CPNowPlayingTemplate.shared

        interfaceController.pushTemplate(nowPlayingTemplate, animated: true) { success, error in
            if let error = error {
                os_log(.error, log: self.logger, "❌ Failed to push Now Playing template: %{public}s", error.localizedDescription)
            } else if success {
                os_log(.info, log: self.logger, "✅ Now Playing template pushed successfully")
            } else {
                os_log(.error, log: self.logger, "❌ Failed to push Now Playing template: success=false, no error")
            }
        }
    }

    // MARK: - Scene Lifecycle

    func sceneDidBecomeActive(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE BECAME ACTIVE")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE WILL RESIGN ACTIVE")
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE ENTERING FOREGROUND")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE ENTERED BACKGROUND")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        os_log(.info, log: logger, "🚗 CARPLAY SCENE DID DISCONNECT")
    }
}
