// File: MediaServicesResetTests.swift
// What to do when iOS resets the audio media services (bd LMS_StreamTest-27ye).
// Captured 2026-10-12: CarPlay Play arrived as the app's audio session died;
// the recreated session had the default category and couldn't play, and the
// reset handler only logged. BASS is now always re-initialized; these cover
// whether playback is then resumed through the playlist-jump recovery.
import Testing
@testable import LMS_StreamTest_tvOS

@MainActor
struct MediaServicesResetTests {
    private typealias Snapshot = SlimProtoCoordinator.MediaServicesSnapshot
    private let idle = Snapshot()

    private func action(_ atLoss: Snapshot?, _ atReset: Snapshot) -> SlimProtoCoordinator.MediaServicesResetAction {
        SlimProtoCoordinator.mediaServicesResetAction(atLoss: atLoss, atReset: atReset)
    }

    @Test func playingAtLossResumes() {
        // At the reset the streams are already freed, so only the loss knows.
        #expect(action(Snapshot(audioPlaying: true), idle) == .reinitializeAndResume)
    }

    @Test func outageHoldAtLossResumes() {
        // The captured case: remote Play after a long background had the hold on.
        #expect(action(Snapshot(outageHoldActive: true), idle) == .reinitializeAndResume)
    }

    @Test func audibleRecoveryInFlightResumes() {
        #expect(action(Snapshot(audibleRecoveryInProgress: true), idle) == .reinitializeAndResume)
    }

    @Test func pausedOrIdleOnlyReinitializes() {
        #expect(action(idle, idle) == .reinitialize)
        #expect(action(nil, idle) == .reinitialize)
    }

    @Test func resetWithoutLossUsesStateAtReset() {
        #expect(action(nil, Snapshot(audioPlaying: true)) == .reinitializeAndResume)
    }

    @Test func playRequestedBetweenLossAndResetResumes() {
        // Remote Play or a server start arrived while output was suspended.
        #expect(action(idle, Snapshot(outageHoldActive: true)) == .reinitializeAndResume)
        #expect(action(idle, Snapshot(startDroppedWhileSuspended: true)) == .reinitializeAndResume)
    }

    @Test func silentRecoveryStreamDroppedDoesNotResume() {
        // App-open recovery's muted stream is not a request to play.
        let silent = Snapshot(silentRecoveryInProgress: true, startDroppedWhileSuspended: true)
        #expect(action(idle, silent) == .reinitialize)
        #expect(action(Snapshot(silentRecoveryInProgress: true), silent) == .reinitialize)
    }
}
