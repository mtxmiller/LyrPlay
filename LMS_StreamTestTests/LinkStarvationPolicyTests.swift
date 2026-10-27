// File: LinkStarvationPolicyTests.swift
// A slow link (cellular, device log 2026-10-24): the user's pause takes effect
// on the phone at once and survives LMS dropping it while buffering; a stream
// that runs dry is reported (STMo) so LMS rebuffers instead of us chopping.
import Testing
@testable import LMS_StreamTest

struct UserPausePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func playingOrStalledAudioPausesOnThePhone() {
        #expect(UserPausePolicy.pausesLocally(playerState: "Playing"))
        // BASS stalled waiting for data: the listener hears silence and presses pause.
        #expect(UserPausePolicy.pausesLocally(playerState: "Buffering"))
    }

    @Test func alreadyPausedOrNoStreamLeavesTheEngineAlone() {
        #expect(!UserPausePolicy.pausesLocally(playerState: "Paused"))
        #expect(!UserPausePolicy.pausesLocally(playerState: "No Stream"))
        #expect(!UserPausePolicy.pausesLocally(playerState: "Stopped"))
    }

    @Test func unpauseBeforeConfirmationIsHeld() {
        // LMS filled its buffer and resumed: the pause it ignored must be sent again.
        #expect(UserPausePolicy.holdsUnpause(pendingSince: now.addingTimeInterval(-12), now: now, window: 60,
                                             resends: 0, maxResends: 3))
    }

    @Test func unpauseWithNoPendingPauseGoesThrough() {
        #expect(!UserPausePolicy.holdsUnpause(pendingSince: nil, now: now, window: 60, resends: 0, maxResends: 3))
    }

    @Test func staleOrExhaustedPendingPauseGoesThrough() {
        // A pause from long ago must not block a resume made elsewhere.
        #expect(!UserPausePolicy.holdsUnpause(pendingSince: now.addingTimeInterval(-61), now: now, window: 60,
                                              resends: 0, maxResends: 3))
        #expect(!UserPausePolicy.holdsUnpause(pendingSince: now.addingTimeInterval(-5), now: now, window: 60,
                                              resends: 3, maxResends: 3))
    }

    @Test func pollStillPlayingAfterAWhileResends() {
        #expect(UserPausePolicy.resendsOnPoll(pendingSince: now.addingTimeInterval(-5), now: now, serverMode: "play",
                                              minimumAge: 4, resends: 0, maxResends: 3))
    }

    @Test func pollDoesNotResendTooSoonOrWhenPausedOrExhausted() {
        // The first request may still be in flight.
        #expect(!UserPausePolicy.resendsOnPoll(pendingSince: now.addingTimeInterval(-2), now: now, serverMode: "play",
                                               minimumAge: 4, resends: 0, maxResends: 3))
        #expect(!UserPausePolicy.resendsOnPoll(pendingSince: now.addingTimeInterval(-5), now: now, serverMode: "pause",
                                               minimumAge: 4, resends: 0, maxResends: 3))
        #expect(!UserPausePolicy.resendsOnPoll(pendingSince: now.addingTimeInterval(-5), now: now, serverMode: "play",
                                               minimumAge: 4, resends: 3, maxResends: 3))
        #expect(!UserPausePolicy.resendsOnPoll(pendingSince: nil, now: now, serverMode: "play",
                                               minimumAge: 4, resends: 0, maxResends: 3))
    }
}

struct OutputUnderrunPolicyTests {
    private func reports(state: String = "Buffering", open: Bool = true, complete: Bool = false, copy: Bool = false,
                         deciding: Bool = false, connected: Bool = true, awaiting: Bool = false, soFar: Int = 0) -> Bool {
        OutputUnderrunPolicy.reports(playerState: state, downloadOpen: open, decodeComplete: complete,
                                     playingCopy: copy, deciding: deciding, serverConnected: connected,
                                     awaitingServer: awaiting, reportsSoFar: soFar)
    }

    @Test func starvedServerStreamIsReported() {
        #expect(reports())
    }

    @Test func onlyAnEngineThatWasPlayingCounts() {
        // A trickle of data can have BASS "Playing" again by the time the
        // stall is looked at; paused or stopped, the drain was asked for.
        #expect(reports(state: "Playing"))
        #expect(!reports(state: "Paused"))
        #expect(!reports(state: "Stopped"))
        #expect(!reports(state: "No Stream"))
    }

    @Test func cutDownloadFinishedDecodeAndCopiesAreNotUnderruns() {
        #expect(!reports(open: false))        // the outage path owns a cut download
        #expect(!reports(complete: true))     // drained after the end of the data: STMu's case
        #expect(!reports(copy: true))         // a saved copy plays from disk
        #expect(!reports(deciding: true))     // the strm is still being decided
        #expect(!reports(connected: false))   // nobody to tell
    }

    @Test func oneReportPerStallUntilLMSAnswers() {
        #expect(!reports(awaiting: true))
    }

    @Test func rebuffersPerSongAreBounded() {
        #expect(reports(soFar: OutputUnderrunPolicy.maxReportsPerStream - 1))
        #expect(!reports(soFar: OutputUnderrunPolicy.maxReportsPerStream))
    }

    @Test func pauseRightAfterOurReportIsARebuffer() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(OutputUnderrunPolicy.pauseIsRebuffer(reportedAt: now.addingTimeInterval(-1), now: now))
        #expect(!OutputUnderrunPolicy.pauseIsRebuffer(reportedAt: now.addingTimeInterval(-10), now: now))
        #expect(!OutputUnderrunPolicy.pauseIsRebuffer(reportedAt: nil, now: now))
    }
}

struct DownloadHoldPolicyTests {
    private func holds(holding: Bool = false, state: String = "Playing", open: Bool = true, complete: Bool = false,
                       copy: Bool = false, rebuffering: Bool = false, buffered: Double) -> Bool {
        DownloadHoldPolicy.holds(holding: holding, playerState: state, downloadOpen: open, decodeComplete: complete,
                                 playingCopy: copy, rebuffering: rebuffering, bufferedSeconds: buffered)
    }

    @Test func aStreamBehindHoldsTheDownloads() {
        #expect(holds(buffered: 6))
        // BASS stalled waiting for data: the stream is as far behind as it gets.
        #expect(holds(state: "Buffering", buffered: 0))
    }

    @Test func aHealthyStreamLetsThemRun() {
        #expect(!holds(buffered: 28))
        // Between the marks and not holding: no reason to start.
        #expect(!holds(buffered: 20))
    }

    @Test func aHoldLastsUntilTheQueueIsComfortablyFull() {
        #expect(holds(holding: true, buffered: 20))
        #expect(!holds(holding: true, buffered: 26))
    }

    @Test func lmsRebufferingUsHoldsWhateverTheEngineSays() {
        #expect(holds(state: "Paused", rebuffering: true, buffered: 2))
    }

    @Test func theUsersPauseFreesTheLink() {
        #expect(!holds(state: "Paused", buffered: 2))
        #expect(!holds(holding: true, state: "Paused", buffered: 2))
    }

    @Test func nothingToCompeteWithNeverHolds() {
        #expect(!holds(open: false, buffered: 2))            // the download ended
        #expect(!holds(complete: true, buffered: 2))         // the whole song is decoded
        #expect(!holds(copy: true, buffered: 2))             // a saved copy plays, no stream
        #expect(!holds(holding: true, copy: true, rebuffering: true, buffered: 0))
    }
}
