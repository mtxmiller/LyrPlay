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

// Round 2 review fixes (bd 27ye).
@MainActor
struct MediaServicesResetReviewTests {
    private typealias Coordinator = SlimProtoCoordinator

    @Test func silentRecoveryStreamPlayingDoesNotResume() {
        // The muted app-open stream counts as "playing"; resuming it audibly breaks rule 12.
        let silent = Coordinator.MediaServicesSnapshot(audioPlaying: true, silentRecoveryInProgress: true)
        #expect(Coordinator.mediaServicesResetAction(atLoss: silent, atReset: Coordinator.MediaServicesSnapshot()) == .reinitialize)
        #expect(Coordinator.mediaServicesResetAction(atLoss: nil, atReset: silent) == .reinitialize)
    }

    @Test func missingIndexIsNotTrackZero() {
        // A save that wrote only position + timestamp right after a jump deleted the index.
        #expect(Coordinator.savedRecoveryTarget(hasTimestamp: true, index: nil, position: 94.94) == nil)
        #expect(Coordinator.savedRecoveryTarget(hasTimestamp: true, index: 47, position: 94.94)
                == Coordinator.RecoveryTarget(index: 47, position: 94.94))
        #expect(Coordinator.savedRecoveryTarget(hasTimestamp: false, index: 47, position: 94.94) == nil)
    }

    @Test func playlistIndexFromServerStatus() {
        // LMS sends playlist_cur_index as a string (checked against the test server).
        #expect(Coordinator.playlistIndex(fromStatus: ["playlist_cur_index": "47"]) == 47)
        #expect(Coordinator.playlistIndex(fromStatus: ["playlist_cur_index": 47]) == 47)
        #expect(Coordinator.playlistIndex(fromStatus: ["mode": "play"]) == nil)
        #expect(Coordinator.playlistIndex(fromStatus: nil) == nil)
    }

    @Test func bassFreeAndInitErrorHandling() {
        // Codes from bass.h: BASS_ERROR_INIT 8, BASS_ERROR_ALREADY 14, BASS_ERROR_BUSY 46.
        #expect(AudioPlayer.freeFailureNeedsRetryLater(46))
        #expect(!AudioPlayer.freeFailureNeedsRetryLater(8))
        #expect(AudioPlayer.initFailureNeedsFreeFirst(14))
        #expect(!AudioPlayer.initFailureNeedsFreeFirst(46))
    }

    @Test func uninitializedBassIsNotATrackError() {
        // BASS_ERROR_INIT (8) must not send STMn: LMS would skip track after track.
        #expect(!AudioStreamDecoder.openFailureIsTrackError(8))
        #expect(AudioStreamDecoder.openFailureIsTrackError(40))  // BASS_ERROR_TIMEOUT
    }

    @Test func duplicateResetIsIgnored() {
        #expect(Coordinator.isDuplicateReset(secondsSinceResetReinit: 2, lostSinceReinit: false))
        #expect(!Coordinator.isDuplicateReset(secondsSinceResetReinit: 2, lostSinceReinit: true))
        #expect(!Coordinator.isDuplicateReset(secondsSinceResetReinit: 30, lostSinceReinit: false))
        // Last re-init came from the 10s no-reset fallback, not a reset: the real reset still re-inits.
        #expect(!Coordinator.isDuplicateReset(secondsSinceResetReinit: nil, lostSinceReinit: false))
    }
}

// Round 3 review fixes (bd 27ye): a missing recovery index is looked up on
// the server instead of falling back to a plain play/pause.
@MainActor
struct MissingRecoveryIndexTests {
    private typealias Coordinator = SlimProtoCoordinator

    @Test func missingIndexWithPositionAsksServer() {
        #expect(Coordinator.needsServerRecoveryIndex(hasTimestamp: true, hasIndex: false, position: 94.94, isAudibleRetry: false))
    }

    @Test func noServerLookupWhenNotNeeded() {
        // Index present, nothing saved, no position, or the outage's kept target wins (build 9).
        #expect(!Coordinator.needsServerRecoveryIndex(hasTimestamp: true, hasIndex: true, position: 94.94, isAudibleRetry: false))
        #expect(!Coordinator.needsServerRecoveryIndex(hasTimestamp: false, hasIndex: false, position: 94.94, isAudibleRetry: false))
        #expect(!Coordinator.needsServerRecoveryIndex(hasTimestamp: true, hasIndex: false, position: 0, isAudibleRetry: false))
        #expect(!Coordinator.needsServerRecoveryIndex(hasTimestamp: true, hasIndex: false, position: 94.94, isAudibleRetry: true))
    }

    @Test func serverIndexBecomesTheJumpTarget() {
        // LMS sends both fields as strings or numbers depending on version.
        let status: [String: Any] = ["mode": "stop", "playlist_cur_index": "47", "playlist_tracks": 120]
        let index = Coordinator.serverRecoveryIndex(fromStatus: status)
        #expect(index == 47)
        #expect(Coordinator.resolveRecoveryTarget(
            saved: index.map { Coordinator.RecoveryTarget(index: $0, position: 94.94) },
            kept: nil, isAudibleRetry: false) == Coordinator.RecoveryTarget(index: 47, position: 94.94))
        #expect(Coordinator.serverRecoveryIndex(fromStatus: ["playlist_cur_index": 3, "playlist_tracks": "5"]) == 3)
    }

    @Test func failedOrEmptyStatusFallsBackToPlainCommand() {
        // nil target → finishRecoveryWithoutJump (plain play/pause).
        #expect(Coordinator.serverRecoveryIndex(fromStatus: nil) == nil)
        #expect(Coordinator.serverRecoveryIndex(fromStatus: ["mode": "stop", "playlist_tracks": 0]) == nil)
        #expect(Coordinator.resolveRecoveryTarget(saved: nil, kept: nil, isAudibleRetry: false) == nil)
    }

    @Test func boundaryDoesNotInventAnIndex() {
        #expect(Coordinator.indexAfterBoundary(nil) == nil)
        #expect(Coordinator.indexAfterBoundary(46) == 47)
    }
}
