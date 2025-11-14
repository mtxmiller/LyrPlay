import CarPlay
import os.log

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let logger = OSLog(subsystem: "com.lmsstream", category: "CarPlay")
    var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        os_log(.info, log: logger, "CarPlay connected")

        // Set up the Now Playing template
        let nowPlayingTemplate = CPNowPlayingTemplate.shared
        interfaceController.setRootTemplate(nowPlayingTemplate, animated: false, completion: nil)

        os_log(.info, log: logger, "CarPlay Now Playing template set")
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        os_log(.info, log: logger, "CarPlay disconnected")
    }
}
