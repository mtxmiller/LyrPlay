import XCTest
@testable import LMS_StreamTest

/// Deterministic coverage for the GH#75 volume-rocker state machine —
/// the engage rules, KVO-delta press classification, pending re-center
/// counter, coalescing window, and launch-recovery rule. These mechanisms
/// were race-hardened during design review; this suite is their regression
/// net (eng-review finding 5A).
final class VolumeRockerLogicTests: XCTestCase {

    private let localMAC = "aa:bb:cc:dd:ee:ff"

    private func conditions(
        selected: String? = "11:22:33:44:55:66",
        appActive: Bool = true,
        busy: Bool = false,
        featureEnabled: Bool = true,
        fixedVolume: Bool = false
    ) -> VolumeRockerLogic.Conditions {
        VolumeRockerLogic.Conditions(
            selectedPlayerID: selected,
            localPlayerID: localMAC,
            appActive: appActive,
            localPlayerBusy: busy,
            featureEnabled: featureEnabled,
            selectedPlayerFixedVolume: fixedVolume
        )
    }

    /// Helper: engage and drain the engage-write's recenter event so tests
    /// start from a clean engaged state.
    private func engagedLogic() -> VolumeRockerLogic {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions()), [.engage, .recenter])
        // Shell writes 0.5; KVO fires ≈0.5 and is swallowed by the counter.
        XCTAssertEqual(logic.volumeChanged(from: 0.3, to: 0.5, at: 0), [])
        XCTAssertEqual(logic.pendingRecenters, 0)
        return logic
    }

    // MARK: - Engage rules

    func testEngagesForExternalPlayerWhileIdle() {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions()), [.engage, .recenter])
        XCTAssertTrue(logic.isEngaged)
    }

    func testDoesNotEngageForLocalPlayerCaseInsensitive() {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions(selected: "AA:BB:CC:DD:EE:FF")), [])
        XCTAssertFalse(logic.isEngaged)
    }

    func testDoesNotEngageWhileLocalPlayerBusy() {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions(busy: true)), [])
    }

    func testDoesNotEngageWhileAppInactive() {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions(appActive: false)), [])
    }

    func testDoesNotEngageWithUnknownPlayer() {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions(selected: nil)), [])
    }

    func testDoesNotEngageWhenFeatureDisabled() {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions(featureEnabled: false)), [])
        XCTAssertFalse(logic.isEngaged)
    }

    func testDoesNotEngageForFixedVolumePlayer() {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions(fixedVolume: true)), [])
        XCTAssertFalse(logic.isEngaged)
    }

    func testDisengagesWhenFeatureTurnedOff() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.evaluate(conditions(featureEnabled: false)), [.disengage])
        XCTAssertFalse(logic.isEngaged)
    }

    func testDisengagesWhenSelectedPlayerReportsFixedVolume() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.evaluate(conditions(fixedVolume: true)), [.disengage])
        XCTAssertFalse(logic.isEngaged)
    }

    func testRepeatedEvaluationIsIdempotent() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.evaluate(conditions()), [])
        XCTAssertTrue(logic.isEngaged)
    }

    // MARK: - Disengage triggers

    func testDisengagesWhenPlayerSwitchesToLocal() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.evaluate(conditions(selected: localMAC)), [.disengage])
        XCTAssertFalse(logic.isEngaged)
    }

    func testDisengagesWhenPlayerBecomesUnknown() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.evaluate(conditions(selected: nil)), [.disengage])
    }

    func testDisengagesWhenLocalPlaybackStarts() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.evaluate(conditions(busy: true)), [.disengage])
    }

    func testDisengagesWhenAppGoesInactive() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.evaluate(conditions(appActive: false)), [.disengage])
    }

    // MARK: - Press classification

    func testVolumeUpClassifiesAsPressUp() {
        var logic = engagedLogic()
        // Midrange press: classify by delta, NO recenter (lazy recenter).
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0), [.pressUp])
        XCTAssertEqual(logic.pendingRecenters, 0)
    }

    func testVolumeDownClassifiesAsPressDown() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.45, at: 1.0), [.pressDown])
        XCTAssertEqual(logic.pendingRecenters, 0)
    }

    // MARK: - Lazy recenter (GH#75 lag fix)

    func testMidrangePressesDoNotRecenter() {
        // The core of the lag fix: repeated midrange presses classify but never
        // recenter, so there is no post-press detection blackout in the shell.
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.5625, at: 1.0), [.pressUp])
        XCTAssertEqual(logic.volumeChanged(from: 0.5625, to: 0.625, at: 1.3), [.pressUp])
        XCTAssertEqual(logic.volumeChanged(from: 0.625, to: 0.6875, at: 1.6), [.pressUp])
        XCTAssertEqual(logic.pendingRecenters, 0)
    }

    func testRecenterFiresAtUpperBandEdge() {
        // A press that drifts the slider to the top of the detectable band
        // recenters so the next up-press can't pin against the rail undetected.
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.875, to: 0.9375, at: 1.0), [.pressUp, .recenter])
        XCTAssertEqual(logic.pendingRecenters, 1)
    }

    func testRecenterFiresAtLowerBandEdge() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.125, to: 0.0625, at: 1.0), [.pressDown, .recenter])
        XCTAssertEqual(logic.pendingRecenters, 1)
    }

    func testRailRecenterEchoDrainsAndDetectionSurvives() {
        // After a rail recenter, the baseline write echo drains the counter, and
        // the next press classifies normally — the counter must not strand
        // detection.
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.875, to: 0.9375, at: 1.0), [.pressUp, .recenter])
        XCTAssertEqual(logic.pendingRecenters, 1)
        // Recenter write echo back to baseline (0.5) is swallowed.
        XCTAssertEqual(logic.volumeChanged(from: 0.9375, to: 0.5, at: 1.2), [])
        XCTAssertEqual(logic.pendingRecenters, 0)
        // Detection alive: a fresh midrange press classifies, no recenter.
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.5625, at: 2.0), [.pressUp])
    }

    func testNoChangeEventIsIgnored() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.5, at: 1.0), [])
    }

    func testEventsIgnoredWhileDisengaged() {
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0), [])
    }

    // MARK: - Coalescing window (≤1 press per 200 ms)

    func testSecondEventInsideWindowIsCoalesced() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0), [.pressUp])
        // 100 ms later (Control Center drag / OS-coalesced burst): no press,
        // and no recenter in the midrange.
        XCTAssertEqual(logic.volumeChanged(from: 0.55, to: 0.6, at: 1.1), [])
        XCTAssertEqual(logic.pendingRecenters, 0)
    }

    func testEventAfterWindowPressesAgain() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0), [.pressUp])
        // Within the 200 ms window: coalesced away.
        XCTAssertEqual(logic.volumeChanged(from: 0.55, to: 0.6, at: 1.1), [])
        // After the window: classifies again, still midrange so no recenter.
        XCTAssertEqual(logic.volumeChanged(from: 0.6, to: 0.65, at: 1.3), [.pressUp])
        XCTAssertEqual(logic.pendingRecenters, 0)
    }

    // MARK: - Re-center counter bookkeeping

    func testCounterNeverExceedsOne() {
        var logic = engagedLogic()
        // Drift to the upper band edge — recenter fires once, counter → 1.
        XCTAssertEqual(logic.volumeChanged(from: 0.875, to: 0.9375, at: 1.0), [.pressUp, .recenter])
        XCTAssertEqual(logic.pendingRecenters, 1)
        // A coalesced burst still at/over the rail must not stack a second recenter.
        _ = logic.volumeChanged(from: 0.9375, to: 1.0, at: 1.05)
        XCTAssertEqual(logic.pendingRecenters, 1)
        // Single recenter write echo (back to baseline 0.5) drains it fully.
        XCTAssertEqual(logic.volumeChanged(from: 1.0, to: 0.5, at: 1.2), [])
        XCTAssertEqual(logic.pendingRecenters, 0)
    }

    func testReengageAfterDisengageResetsState() {
        var logic = engagedLogic()
        _ = logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0)
        XCTAssertEqual(logic.evaluate(conditions(selected: localMAC)), [.disengage])
        XCTAssertEqual(logic.pendingRecenters, 0)
        XCTAssertEqual(logic.evaluate(conditions()), [.engage, .recenter])
        XCTAssertEqual(logic.pendingRecenters, 1)
    }

    // MARK: - Launch recovery rule (eng-review 4A)

    func testStaleRestoreReturnsPersistedValue() {
        XCTAssertEqual(VolumeRockerLogic.staleRestoreVolume(persisted: 0.4), 0.4)
    }

    func testStaleRestoreNilWhenNothingPersisted() {
        XCTAssertNil(VolumeRockerLogic.staleRestoreVolume(persisted: nil))
    }

    func testStaleRestoreRejectsOutOfRangeValues() {
        XCTAssertNil(VolumeRockerLogic.staleRestoreVolume(persisted: 1.5))
        XCTAssertNil(VolumeRockerLogic.staleRestoreVolume(persisted: -0.1))
    }

    // MARK: - Working baseline (no-jump engage)

    func testWorkingBaselineLeavesMidrangeUntouched() {
        // The whole point: a normal volume is NOT moved to 0.5 on engage.
        XCTAssertEqual(VolumeRockerLogic.workingBaseline(for: 0.30), 0.30, accuracy: 0.0001)
        XCTAssertEqual(VolumeRockerLogic.workingBaseline(for: 0.65), 0.65, accuracy: 0.0001)
    }

    func testWorkingBaselineNudgesOnlyNearTheRails() {
        // Muted / near-mute gets nudged up exactly one step so a down-press
        // stays detectable; near-max gets nudged down one step.
        XCTAssertEqual(VolumeRockerLogic.workingBaseline(for: 0.0), VolumeRockerLogic.baselineMin, accuracy: 0.0001)
        XCTAssertEqual(VolumeRockerLogic.workingBaseline(for: 0.02), VolumeRockerLogic.baselineMin, accuracy: 0.0001)
        XCTAssertEqual(VolumeRockerLogic.workingBaseline(for: 1.0), VolumeRockerLogic.baselineMax, accuracy: 0.0001)
    }

    func testRecenterSwallowUsesPassedBaselineNotHalf() {
        // With a low baseline, the recenter write lands at the baseline (not
        // 0.5) and must still be swallowed.
        var logic = VolumeRockerLogic()
        XCTAssertEqual(logic.evaluate(conditions()), [.engage, .recenter])
        XCTAssertEqual(logic.volumeChanged(from: 0.05, to: 0.0625, at: 0, target: 0.0625), [])
        XCTAssertEqual(logic.pendingRecenters, 0)
        // A real up-press from that low baseline classifies; 0.125 is back
        // inside the band so no recenter is needed (lazy recenter).
        XCTAssertEqual(logic.volumeChanged(from: 0.0625, to: 0.125, at: 1.0, target: 0.0625),
                       [.pressUp])
    }

    func testStaleRestoreAcceptsBoundaries() {
        XCTAssertEqual(VolumeRockerLogic.staleRestoreVolume(persisted: 0.0), 0.0)
        XCTAssertEqual(VolumeRockerLogic.staleRestoreVolume(persisted: 1.0), 1.0)
    }
}
