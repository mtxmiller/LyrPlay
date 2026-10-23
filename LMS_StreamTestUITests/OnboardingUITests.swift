// File: OnboardingUITests.swift
// Walks the real first-run setup (Welcome → Your Server → Connection → Your
// Player) against a live LMS and checks ON THE SERVER that the player arrived
// connected under the name that was typed — the server-as-oracle rule.
//
// Environment (pass to xcodebuild with the TEST_RUNNER_ prefix):
//   LYRPLAY_LMS_HOST  LYRPLAY_LMS_PORT  LYRPLAY_SLIM_PORT   (default: lms-test)
//   LYRPLAY_LMS_USER  LYRPLAY_LMS_PASS   for a password-protected server
//   LYRPLAY_SHOTS_DIR  a directory to save a screenshot of each step into
//
// Each run uses a new player ID (launch argument) and forgets it on the
// server afterwards, so the test server does not fill up with players.
import XCTest

final class OnboardingUITests: XCTestCase {

    private var host: String { env("LYRPLAY_LMS_HOST") ?? "192.168.1.8" }
    private var webPort: String { env("LYRPLAY_LMS_PORT") ?? "9010" }
    private var slimPort: String { env("LYRPLAY_SLIM_PORT") ?? "3490" }
    private var username: String { env("LYRPLAY_LMS_USER") ?? "" }
    private var password: String { env("LYRPLAY_LMS_PASS") ?? "" }

    private let playerID = "02:" + (0..<5).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined(separator: ":")
    private var playerName = "UITest Setup \(Int.random(in: 100...999))"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
        _ = try? request(["client", "forget"], player: playerID)
    }

    func testFirstRunSetupConnectsThePlayer() throws {
        let app = XCUIApplication()
        // Unconfigured, with a fresh player ID: the argument domain overrides
        // whatever the simulator's last run left in the app's defaults.
        app.launchArguments += ["-IsConfigured", "NO", "-PlayerMACAddress", playerID]
        app.launch()

        // Welcome
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 10), "Welcome step did not appear")
        snapshot("1-welcome")
        getStarted.tap()

        // Your Server
        let hostField = app.textFields["onboarding.host"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 10), "Server step did not appear")
        replaceText(in: hostField, with: host)
        replaceText(in: app.textFields["onboarding.webPort"], with: webPort)
        replaceText(in: app.textFields["onboarding.slimPort"], with: slimPort)
        replaceText(in: app.textFields["onboarding.username"], with: username)
        replaceText(in: app.secureTextFields["onboarding.password"], with: password)
        snapshot("2-server")
        app.buttons["onboarding.continue"].tap()

        // Connection
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 30),
                      "Connection check did not succeed against \(host):\(webPort)/\(slimPort)")
        snapshot("3-connection")
        app.buttons["onboarding.continue"].tap()

        // Your Player
        let nameField = app.textFields["onboarding.playerName"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Player step did not appear")
        replaceText(in: nameField, with: playerName)
        snapshot("4-player")
        app.buttons["onboarding.finish"].tap()

        // The server is the oracle: the player must be connected under its name.
        let deadline = Date().addingTimeInterval(30)
        var seen: [String] = []
        while Date() < deadline {
            if let players = try? connectedPlayers() {
                seen = players
                if players.contains(playerName) { break }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(seen.contains(playerName),
                      "Player '\(playerName)' never connected to \(host); connected players: \(seen)")
        // Material has had a moment to load behind the oracle check.
        snapshot("5-material")
    }

    // MARK: - Helpers

    private func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    /// Clears a field's current text and types the new value (nothing when empty).
    private func replaceText(in element: XCUIElement, with text: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) missing")
        // The keyboard from the previous field may cover this one: a drag on
        // the form puts it away (scrollDismissesKeyboard), then the row is
        // tappable again.
        let app = XCUIApplication()
        if app.keyboards.count > 0 {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !element.isHittable {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Put the cursor at the end (the port fields are right-aligned), then
        // delete back over whatever is there.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        if let current = element.value as? String, !current.isEmpty,
           current != element.placeholderValue {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        if !text.isEmpty {
            element.typeText(text)
        }
    }

    private func snapshot(_ name: String) {
        guard let dir = env("LYRPLAY_SHOTS_DIR") else { return }
        // Forms put the keyboard away on a drag (iOS 16+), so the picture
        // shows the step, not the keyboard.
        XCUIApplication().swipeDown()
        Thread.sleep(forTimeInterval: 0.6)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func connectedPlayers() throws -> [String] {
        let result = try request(["players", 0, 50], player: "")
        let loop = (result["players_loop"] as? [[String: Any]]) ?? []
        return loop.compactMap { player in
            let connected = (player["connected"] as? Int) ?? Int("\(player["connected"] ?? "0")") ?? 0
            return connected == 1 ? player["name"] as? String : nil
        }
    }

    /// One JSON-RPC call to the test server (Basic auth when the env gives credentials).
    private func request(_ command: [Any], player: String) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "http://\(host):\(webPort)/jsonrpc.js")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "id": 1, "method": "slim.request", "params": [player, command]
        ])
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?
        URLSession.shared.dataTask(with: req) { data, _, error in
            payload = data
            failure = error
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let failure = failure { throw failure }
        let json = try JSONSerialization.jsonObject(with: payload ?? Data()) as? [String: Any]
        return (json?["result"] as? [String: Any]) ?? [:]
    }
}
