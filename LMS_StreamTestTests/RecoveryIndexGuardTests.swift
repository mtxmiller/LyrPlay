// File: RecoveryIndexGuardTests.swift
// Stale-rejection guard for server-derived recovery-index writes
// (bd LMS_StreamTest-433.5.4). A status-poll response that left the server
// BEFORE a gapless boundary must not rewind the locally-incremented index.
import Testing
@testable import LMS_StreamTest

struct RecoveryIndexGuardTests {

    @Test func forwardMoveAlwaysAccepted() {
        #expect(SlimProtoCoordinator.acceptServerRecoveryIndex(
            current: 3, proposed: 4, secondsSinceBoundaryBump: 0.5))
    }

    @Test func matchingIndexAlwaysAccepted() {
        #expect(SlimProtoCoordinator.acceptServerRecoveryIndex(
            current: 3, proposed: 3, secondsSinceBoundaryBump: 0.5))
    }

    @Test func backwardMoveRejectedInsidePostBoundaryWindow() {
        // The failure case: poll left the server before the boundary, landed
        // 2s after the local increment → would jump recovery to the previous track.
        #expect(!SlimProtoCoordinator.acceptServerRecoveryIndex(
            current: 4, proposed: 3, secondsSinceBoundaryBump: 2.0))
    }

    @Test func backwardMoveAcceptedAfterWindow() {
        // Legitimate backward move: user selected an earlier playlist track.
        #expect(SlimProtoCoordinator.acceptServerRecoveryIndex(
            current: 4, proposed: 1, secondsSinceBoundaryBump: 30.0))
    }

    @Test func backwardMoveAcceptedWhenNoBoundaryEverBumped() {
        // Fresh install: bump stamp is 0 → sinceBump is huge → accept.
        #expect(SlimProtoCoordinator.acceptServerRecoveryIndex(
            current: 4, proposed: 2, secondsSinceBoundaryBump: 1_000_000))
    }
}
