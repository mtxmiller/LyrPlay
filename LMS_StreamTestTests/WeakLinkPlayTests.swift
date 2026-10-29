// File: WeakLinkPlayTests.swift
// A play pressed while paused with no live connection asks the server first
// (a suspended app with the network fine must reach LMS). On a weak link the
// socket may connect but the server is never heard, while iOS still reports
// a network: then the saved copies play (bd kpu0).
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
}
