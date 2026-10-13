// File: RecoveryTargetTests.swift
// Audible recovery retries reuse the outage's original jump target
// (bd LMS_StreamTest-fykj). Captured 2026-10-10: the socket dropped just
// before the jump, LMS skipped tracks 12→15 and the retry played track 15
// from 0 because the saved data had been deleted.
import Testing
@testable import LMS_StreamTest

struct RecoveryTargetTests {
    private let original = SlimProtoCoordinator.RecoveryTarget(index: 12, position: 101.68)
    // What the 3s poll / a disconnect save writes after LMS skips through the queue.
    private let skippedTo = SlimProtoCoordinator.RecoveryTarget(index: 15, position: 101.68)

    @Test func firstRecoveryUsesSavedData() {
        #expect(SlimProtoCoordinator.resolveRecoveryTarget(
            saved: original, kept: nil, isAudibleRetry: false) == original)
    }

    @Test func retryAfterSavedDataDeletedUsesKeptTarget() {
        // The captured failure: data deleted on jump accept → plain "play".
        #expect(SlimProtoCoordinator.resolveRecoveryTarget(
            saved: nil, kept: original, isAudibleRetry: true) == original)
    }

    @Test func retryIgnoresIndexOverwrittenBySkipThrough() {
        #expect(SlimProtoCoordinator.resolveRecoveryTarget(
            saved: skippedTo, kept: original, isAudibleRetry: true) == original)
    }

    @Test func nonRetryIgnoresKeptTarget() {
        // Silent recovery or a new hold: the saved data is current.
        #expect(SlimProtoCoordinator.resolveRecoveryTarget(
            saved: skippedTo, kept: original, isAudibleRetry: false) == skippedTo)
    }

    @Test func nothingSavedAndNothingKeptMeansNoJump() {
        #expect(SlimProtoCoordinator.resolveRecoveryTarget(
            saved: nil, kept: nil, isAudibleRetry: false) == nil)
    }
}
