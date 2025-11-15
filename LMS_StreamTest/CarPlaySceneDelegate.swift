import UIKit
import CarPlay
import os.log

@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "CarPlay")
    var interfaceController: CPInterfaceController?

    @objc func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        os_log(.info, log: logger, "🚗 CARPLAY WILL CONNECT")
        os_log(.info, log: logger, "  Template Scene: %{public}s", String(describing: templateApplicationScene))
        os_log(.info, log: logger, "  Interface Controller: %{public}s", String(describing: interfaceController))
        os_log(.info, log: logger, "  Session: %{public}s", String(describing: templateApplicationScene.session))

        self.interfaceController = interfaceController
        os_log(.info, log: logger, "  ✅ Interface controller stored")

        // Set up the Now Playing template
        os_log(.info, log: logger, "  Getting CPNowPlayingTemplate.shared...")
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        os_log(.info, log: logger, "  ✅ CPNowPlayingTemplate.shared retrieved: %{public}s", String(describing: nowPlayingTemplate))

        os_log(.info, log: logger, "  Setting root template...")
        interfaceController.setRootTemplate(nowPlayingTemplate, animated: false) { success, error in
            if let error = error {
                os_log(.error, log: self.logger, "❌ FAILED to set root template: %{public}s", error.localizedDescription)
            } else if success {
                os_log(.info, log: self.logger, "  ✅ Root template set successfully")
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
