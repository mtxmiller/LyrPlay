// File: WeakLinkPlayTests.swift
// A play pressed while paused with no live connection asks the server first
// (a suspended app with the network fine must reach LMS). On a weak link the
// socket may connect but the server is never heard, while iOS still reports
// a network: then the saved copies play (bd kpu0).
import Foundation
import Testing
@testable import LMS_StreamTest

struct WeakLinkPlayTests {
    typealias Facts = SlimProtoCoordinator.SilentPlayFacts
    private func decide(_ f: Facts) -> Bool { SlimProtoCoordinator.playFromCopiesAfterSilentPlay(f) }

    @Test func connectThatStaysSilentPlaysTheCopies() {
        // Weak link: TCP accepted, the server never speaks.
        #expect(decide(Facts(sincePress: 6, silentConnectFor: 3)))
    }

    @Test func noConnectYetWaitsLongerThanALostSyn() {
        // A waking cellular radio can lose the first SYN: heard at ~7 s (O11 on cellular).
        #expect(!decide(Facts(sincePress: 7)))
        #expect(!decide(Facts(sincePress: 6, silentConnectFor: 1)))
        #expect(decide(Facts(sincePress: 12)))  // refused or never connecting
    }

    @Test func serverHeardSinceThePressLeavesItToTheServer() {
        #expect(!decide(Facts(sincePress: 12, serverHeardSincePress: true)))
        #expect(!decide(Facts(connectionLive: true, sincePress: 30)))
        // Heard once, then nothing played for 25 s: the link stalled.
        #expect(decide(Facts(sincePress: 25, serverHeardSincePress: true)))
    }

    @Test func aJumpInFlightOwnsTheRecovery() {
        // Its completion or timeout clears the recovery lock; taking over strands it.
        #expect(!decide(Facts(recoveryInProgress: true, sincePress: 30)))
    }

    @Test func noCopiesKeepsTryingTheServer() {
        #expect(!decide(Facts(copiesCoverLastPosition: false, sincePress: 30)))
    }

    @Test func nothingLocalStillPlaysFromTheSavedPosition() {
        // The app-open recovery flushed the paused buffer (opened on the weak link).
        #expect(decide(Facts(localState: "Stopped", sincePress: 12)))
        #expect(decide(Facts(localState: "No Stream", sincePress: 12)))
    }

    @Test func alreadyPlayingOrPausedAgainDoesNothing() {
        #expect(!decide(Facts(localState: "Playing", sincePress: 30)))
        #expect(!decide(Facts(stillWaiting: false, sincePress: 30)))  // a pause ended the hold
    }

    // MARK: SlimProto live, web requests dead (car 2026-11-17)

    @Test func liveSlimProtoWithDeadCommandsPlaysTheCopies() {
        // Small SlimProto frames keep arriving; every JSON-RPC times out; LMS sent no strm.
        #expect(decide(Facts(connectionLive: true, sincePress: 8, serverHeardSincePress: true, commandsDown: true)))
    }

    @Test func liveSlimProtoWithWorkingCommandsLeavesItToTheServer() {
        #expect(!decide(Facts(connectionLive: true, sincePress: 60, serverHeardSincePress: true)))
    }

    @Test func aStrmSinceThePressMeansThePlayReachedLMS() {
        // A slow but working link: replies time out, the command still landed.
        #expect(!decide(Facts(connectionLive: true, sincePress: 20, commandsDown: true, streamSincePress: true)))
    }

    @Test func deadCommandsStillWaitTheMinimumAndTheJump() {
        #expect(!decide(Facts(connectionLive: true, sincePress: 5, commandsDown: true)))
        #expect(!decide(Facts(recoveryInProgress: true, connectionLive: true, sincePress: 20, commandsDown: true)))
        #expect(!decide(Facts(connectionLive: true, copiesCoverLastPosition: false, sincePress: 20, commandsDown: true)))
    }
}

struct CommandChannelLogTests {
    typealias Log = SlimProtoCoordinator.CommandChannelLog
    let press = Date(timeIntervalSince1970: 1_000)

    @Test func twoTimeoutsAfterThePressMeanDown() {
        var log = Log()
        log.noteFailure(started: press.addingTimeInterval(0.5), ended: press.addingTimeInterval(5.5))
        #expect(!log.isDown(since: press))
        log.noteFailure(started: press.addingTimeInterval(2), ended: press.addingTimeInterval(7))
        #expect(log.isDown(since: press))
    }

    @Test func aResponseResetsTheCountInsteadOfProvingTheLink() {
        var log = Log()
        log.noteFailure(started: press.addingTimeInterval(0.5), ended: press.addingTimeInterval(5.5))
        log.noteFailure(started: press.addingTimeInterval(2), ended: press.addingTimeInterval(7))
        log.noteResponse(at: press.addingTimeInterval(8))
        #expect(!log.isDown(since: press))
        // A flapping link: one status got through, then dead again (review of db1f166).
        log.noteFailure(started: press.addingTimeInterval(9), ended: press.addingTimeInterval(14))
        #expect(!log.isDown(since: press))
        log.noteFailure(started: press.addingTimeInterval(10), ended: press.addingTimeInterval(15))
        #expect(log.isDown(since: press))
        // A timeout of a request sent before that response doesn't count.
        var log2 = Log()
        log2.noteFailure(started: press.addingTimeInterval(1), ended: press.addingTimeInterval(9))
        log2.noteResponse(at: press.addingTimeInterval(3))
        log2.noteFailure(started: press.addingTimeInterval(4), ended: press.addingTimeInterval(9))
        #expect(!log2.isDown(since: press))
    }

    @Test func quickFailuresAndOlderRequestsDontCount() {
        var log = Log()
        // A short status check (2 s timeout) or an instant refusal is not a real timeout.
        log.noteFailure(started: press.addingTimeInterval(0.1), ended: press.addingTimeInterval(2.1))
        log.noteFailure(started: press.addingTimeInterval(0.2), ended: press.addingTimeInterval(0.3))
        // Sent before the press.
        log.noteFailure(started: press.addingTimeInterval(-3), ended: press.addingTimeInterval(2))
        log.noteFailure(started: press.addingTimeInterval(1), ended: press.addingTimeInterval(6))
        #expect(!log.isDown(since: press))
    }

    @Test func aResponseBeforeThePressDoesNotHideLaterTimeouts() {
        var log = Log()
        log.noteResponse(at: press.addingTimeInterval(-1))
        log.noteFailure(started: press.addingTimeInterval(1), ended: press.addingTimeInterval(6))
        log.noteFailure(started: press.addingTimeInterval(2), ended: press.addingTimeInterval(7))
        #expect(log.isDown(since: press))
    }
}

struct UndeliveredUserPlayTests {
    typealias C = SlimProtoCoordinator

    @Test func lmsPausedEndsRetriesOnlyWithoutAnUndeliveredPlay() {
        #expect(C.pauseOnServerEndsRetries(userPlayUndeliveredFor: nil))
        #expect(!C.pauseOnServerEndsRetries(userPlayUndeliveredFor: 30))
        #expect(C.pauseOnServerEndsRetries(userPlayUndeliveredFor: C.userPlayUndeliveredLimit + 1))
    }

    @Test func retriesWaitingForTheLinkAreFreeUntilTheLimit() {
        #expect(C.retryWaitsForCommandLink(userPlayUndeliveredFor: 40, commandsDown: true))
        #expect(!C.retryWaitsForCommandLink(userPlayUndeliveredFor: 40, commandsDown: false))
        #expect(!C.retryWaitsForCommandLink(userPlayUndeliveredFor: nil, commandsDown: true))
        #expect(!C.retryWaitsForCommandLink(userPlayUndeliveredFor: C.userPlayUndeliveredLimit + 1, commandsDown: true))
    }

    @Test func savedMusicStartsFromThePlanWhenNoIndexIsSaved() {
        #expect(C.savedMusicIndex(saved: 4, planCurrent: 7) == 4)
        #expect(C.savedMusicIndex(saved: nil, planCurrent: 7) == 7)
        #expect(C.savedMusicIndex(saved: nil, planCurrent: nil) == nil)
    }
}
