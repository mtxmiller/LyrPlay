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

    // REMOVED: ensureActive() no longer exists - BASS auto-manages audio session
    // Manual session activation removed when migrating to BASS auto-management
    func testEnsureActiveSetsCategoryAndActivatesSession() {
        // Test disabled - BASS handles session activation automatically
        /*
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
        */
    }

    // NOTE: These exercise the CURRENT design — BASS auto-manages the AVAudioSession, so the
    // controller drives playback through SlimProto server commands (sendLockScreenCommand),
    // NOT local playbackController.pause()/play() or session setActive(). The earlier versions
    // asserted the pre-BASS-migration behavior and failed on every runtime (misfiled as an
    // "iOS 26 simulator" issue in bd LMS_StreamTest-u91).

    func testInterruptionPausesThenResumesViaServerCommands() {
        fakePlaybackController.isPlayingStub = true

        // Interruption begins while playing → server "pause".
        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])

        // Interruption ends (auto-resume case) → server "play", sent ~0.2s later.
        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [
                                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                    AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
                                ])

        let exp = expectation(description: "server pause then play")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(self.fakeSlimProto.commandsSent, ["pause", "play"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.5)
    }

    func testOtherAudioInterruptionPausesButDoesNotAutoResume() {
        // An interruption classified as "other audio" (WasSuspended) must pause but NOT
        // auto-resume when it ends — we don't fight another audio app for the session.
        fakePlaybackController.isPlayingStub = true

        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [
                                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                                    AVAudioSessionInterruptionWasSuspendedKey: true  // → classified as .otherAudio
                                ])

        notificationCenter.post(name: AVAudioSession.interruptionNotification,
                                object: nil,
                                userInfo: [
                                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                    AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
                                ])

        let exp = expectation(description: "server pause, no resume")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(self.fakeSlimProto.commandsSent, ["pause"])  // no "play"
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.5)
    }

    func testDeviceDisconnectWhilePlayingPausesServer() {
        // CarPlay connect: marks the route active and issues no playback commands.
        fakeAudioSession.currentOutputsStub = [.carAudio]
        notificationCenter.post(name: AVAudioSession.routeChangeNotification,
                                object: nil,
                                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        XCTAssertEqual(fakeSlimProto.commandsSent, [], "connect must not issue playback commands")

        // Output device goes away while playing → server "pause" (BASS handles route teardown;
        // there is no local pause()/setActive here).
        fakePlaybackController.isPlayingStub = true
        fakeAudioSession.currentOutputsStub = [.builtInSpeaker]
        notificationCenter.post(name: AVAudioSession.routeChangeNotification,
                                object: nil,
                                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])

        let exp = expectation(description: "server pause on disconnect")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(self.fakeSlimProto.commandsSent, ["pause"])
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
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

    func sendJSONRPCCommandDirect(_ command: [String: Any],
                                  completion: @escaping ([String: Any]) -> Void) {
        completion([:])
    }

    func toggleShuffleMode(completion: ((Int) -> Void)?) {
        completion?(0)
    }

    func sendPauseWithConfirmation(maxRetries: Int, completion: ((Bool) -> Void)?) {
        completion?(true)
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

    func handleAudioRouteChange() {
        // No-op for tests
    }

    func cleanupPushStreams() {
        // No-op for tests
    }
}
