import XCTest
import MediaPlayer
@testable import LMS_StreamTest

final class PlaybackSessionControllerTests: XCTestCase {
    private var fakeAudioSession: FakeAudioSession!
    private var fakeSlimProto: FakeSlimProtoCoordinator!
    private var fakePlaybackController: FakePlaybackController!
    private var notificationCenter: NotificationCenter!
    private var controller: PlaybackSessionController!

    override func setUp() {
        super.setUp()
        fakeAudioSession = FakeAudioSession()
        fakeSlimProto = FakeSlimProtoCoordinator()
        fakePlaybackController = FakePlaybackController()
        notificationCenter = NotificationCenter()
        controller = PlaybackSessionController(
            audioSession: fakeAudioSession,
            notificationCenter: notificationCenter,
            commandCenter: MPRemoteCommandCenter.shared()
        )

        controller.configure(audioManager: fakePlaybackController) { [weak self] in
            self?.fakeSlimProto
        }
    }

    override func tearDown() {
        controller = nil
        notificationCenter = nil
        fakePlaybackController = nil
        fakeSlimProto = nil
        fakeAudioSession = nil
        super.tearDown()
    }

    func testEnsureActiveSetsCategoryAndActivatesSession() {
        let exp = expectation(description: "activation")
        controller.ensureActive(context: .userInitiatedPlay)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.fakeAudioSession.configureCategoryCalls.count, 1)
            XCTAssertEqual(self.fakeAudioSession.configureCategoryCalls.first?.category, .playback)
            XCTAssertEqual(self.fakeAudioSession.setActiveCalls.count, 1)
            XCTAssertTrue(self.fakeAudioSession.setActiveCalls.first?.active ?? false)
            exp.fulfill()
        }

        waitForExpectations(timeout: 1.0)
    }

    func testInterruptionPausesAndResumesWhenIndicated() {
        fakePlaybackController.isPlayingStub = true

        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])

        let pauseExpectation = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(self.fakePlaybackController.pauseCount, 1)
            pauseExpectation.fulfill()
        }

        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [
                                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                    AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
                                ])

        let exp = expectation(description: "resume")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.fakePlaybackController.playCount, 1)
            XCTAssertEqual(self.fakeAudioSession.setActiveCalls.last?.options, [.notifyOthersOnDeactivation])
            exp.fulfill()
        }

        wait(for: [pauseExpectation, exp], timeout: 1.0)
    }

    func testInterruptionFromOtherAudioDoesNotAutoResume() {
        fakeAudioSession.otherAudioIsPlayingStub = true
        fakePlaybackController.isPlayingStub = true

        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])

        let pauseExpectation = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(self.fakePlaybackController.pauseCount, 1)
            pauseExpectation.fulfill()
        }

        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [
                                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                    AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
                                ])

        let exp = expectation(description: "no resume")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.fakePlaybackController.playCount, 0)
            exp.fulfill()
        }

        wait(for: [pauseExpectation, exp], timeout: 1.0)
    }

    func testCarPlayRouteChangeTriggersConnectAndPause() {
        // Simulate CarPlay connect
        fakeAudioSession.currentOutputsStub = [.carAudio]
        notificationCenter.post(name: AVAudioSession.routeChangeNotification,
                                object: nil,
                                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])

        let connectExpectation = expectation(description: "connect")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            XCTAssertTrue(self.fakeSlimProto.connectCalled)
            XCTAssertEqual(self.fakeSlimProto.commandsSent, [])
            connectExpectation.fulfill()
        }

        wait(for: [connectExpectation], timeout: 1.2)

        // Simulate CarPlay disconnect
        fakePlaybackController.isPlayingStub = true
        fakeAudioSession.currentOutputsStub = [.builtInSpeaker]
        notificationCenter.post(name: AVAudioSession.routeChangeNotification,
                                object: nil,
                                userInfo: [
                                    AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                                ])

        let disconnectExpectation = expectation(description: "disconnect")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(self.fakePlaybackController.pauseCount, 1)
            XCTAssertTrue(self.fakeSlimProto.savedPosition)
            XCTAssertEqual(self.fakeSlimProto.commandsSent, ["pause"])
            disconnectExpectation.fulfill()
        }

        wait(for: [disconnectExpectation], timeout: 0.2)
    }
}

// MARK: - Fakes
private final class FakeAudioSession: AudioSessionManaging {
    struct ConfigureCall { let category: AVAudioSession.Category; let mode: AVAudioSession.Mode; let options: AVAudioSession.CategoryOptions }
    struct ActiveCall { let active: Bool; let options: AVAudioSession.SetActiveOptions }

    var category: AVAudioSession.Category = .ambient
    var mode: AVAudioSession.Mode = .default
    var currentOutputsStub: [AVAudioSession.Port] = [.builtInSpeaker]
    var otherAudioIsPlayingStub: Bool = false

    var configureCategoryCalls: [ConfigureCall] = []
    var setActiveCalls: [ActiveCall] = []

    var currentOutputs: [AVAudioSession.Port] { currentOutputsStub }

    var otherAudioIsPlaying: Bool { otherAudioIsPlayingStub }

    func configureCategory(_ category: AVAudioSession.Category,
                           mode: AVAudioSession.Mode,
                           options: AVAudioSession.CategoryOptions) throws {
        self.category = category
        self.mode = mode
        configureCategoryCalls.append(.init(category: category, mode: mode, options: options))
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        setActiveCalls.append(.init(active: active, options: options))
    }
}

private final class FakeSlimProtoCoordinator: SlimProtoControlling {
    var isConnected: Bool = false
    var connectCalled = false
    var commandsSent: [String] = []
    var savedPosition = false

    func connect() {
        connectCalled = true
        isConnected = true
    }

    func sendLockScreenCommand(_ command: String) {
        commandsSent.append(command)
    }

    func saveCurrentPositionForRecovery() {
        savedPosition = true
    }
}

private final class FakePlaybackController: AudioPlaybackControlling {
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    var isPlayingStub = false

    func play() {
        playCount += 1
        isPlayingStub = true
    }

    func pause() {
        pauseCount += 1
        isPlayingStub = false
    }

    var isPlaying: Bool { isPlayingStub }
}
