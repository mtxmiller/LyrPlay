// File: ResumeRouteTests.swift
// Remote play and app open decide by whether LMS still holds our paused
// stream, not by how long the app was in the background (the old 45s rule).
// LMS closes a player it hasn't heard from for 15s (Slimproto.pm
// check_all_clients); a paused iOS app is suspended and can't answer. A live
// connection alone isn't enough: after a relaunch the new connection is live
// but LMS stopped the player when it dropped the old one.
import Testing
@testable import LMS_StreamTest

struct ResumeRouteTests {
    private func route(live: Bool = true, local: String = "Paused",
                       mode: String? = "pause", connected: Bool? = true) -> SlimProtoCoordinator.ResumeRoute {
        SlimProtoCoordinator.resumeRoute(connectionLive: live, localState: local,
                                         serverMode: mode, serverConnected: connected)
    }

    @Test func pausedStreamStillOnTheServerResumesInPlace() {
        #expect(route() == .resumeInPlace)
    }

    @Test func quietConnectionRecovers() {
        #expect(route(live: false) == .recover)
    }

    @Test func newProcessWithALiveConnectionRecovers() {
        // CarPlay cold-launches the process and connects; autoplay arrives on the
        // live new socket, but we hold no stream and LMS stopped the player.
        #expect(route(local: "No Stream", mode: "stop") == .recover)
    }

    @Test func serverStoppedThePlayerRecovers() {
        // LMS stops a paused client when it reconnects; a plain play would start at 0:00.
        #expect(route(mode: "stop") == .recover)
    }

    @Test func failedOrEmptyStatusRecovers() {
        // LMS 9.2 returns an empty reply for a player it doesn't have.
        #expect(route(mode: nil, connected: nil) == .recover)
    }

    @Test func serverSeesThePlayerDisconnectedRecovers() {
        #expect(route(connected: false) == .recover)
    }

    @Test func serverPlayingIsLeftAlone() {
        // A stall or track gap looks "not paused" locally; a silent jump would
        // land a live session paused.
        #expect(route(local: "Buffering", mode: "play") == .leaveAlone)
        #expect(route(local: "Stopped", mode: "play") == .leaveAlone)
    }

    @Test func serverPausedButWeHoldNoStreamRecovers() {
        #expect(route(local: "No Stream", mode: "pause") == .recover)
    }

    @Test func devicePausedAfterAnInterruptionResumesInPlace() {
        // BASS_ACTIVE_PAUSED_DEVICE reads as "Unknown".
        #expect(route(local: "Unknown", mode: "pause") == .resumeInPlace)
    }

    @Test func windowStaysUnderLMSsCloseTime() {
        // LMS closes after 3 missed 5s polls.
        #expect(SlimProtoCoordinator.liveConnectionWindow < 15)
    }

    @Test func playerConnectedParsesIntAndString() {
        #expect(SlimProtoCoordinator.statusPlayerConnected(["player_connected": 1]) == true)
        #expect(SlimProtoCoordinator.statusPlayerConnected(["player_connected": "0"]) == false)
        #expect(SlimProtoCoordinator.statusPlayerConnected(nil) == nil)
    }
}

// LMS stops a paused player right after it reconnects; the lock screen should
// keep the paused position (where Play recovers to), not drop to 0:00.
struct ReconnectStopTests {
    private func stop(after: TimeInterval? = 0.02, state: String = "Paused",
                      shown: Double = 67.5, saved: Double = 67.5) -> Bool {
        SlimProtoCoordinator.isReconnectStop(connectedFor: after, localState: state,
                                             shownPosition: shown, savedPosition: saved)
    }

    @Test func stopJustAfterConnectWhilePausedIsTheServersReconnectStop() {
        #expect(stop())
    }

    @Test func laterStopsAreReal() {
        #expect(!stop(after: 30))
        #expect(!stop(after: nil))
    }

    @Test func stopWhilePlayingOrWithNothingSavedIsReal() {
        #expect(!stop(state: "Playing"))
        #expect(!stop(saved: 0))
    }

    @Test func aPlayerAlreadyStoppedStaysAtZero() {
        // The user pressed Stop earlier: LMS's forced stop on reconnect must not
        // bring the old position back.
        #expect(!stop(shown: 0))
    }
}
