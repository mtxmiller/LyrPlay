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
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0), [.pressUp, .recenter])
    }

    func testVolumeDownClassifiesAsPressDown() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.45, at: 1.0), [.pressDown, .recenter])
    }

    func testRealPressLandingExactlyOnRecenterTarget() {
        // Spike-verified: hardware steps are 0.05, so 0.55 → 0.50 is a real
        // down-press. With the counter drained it must classify, not be
        // swallowed.
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0), [.pressUp, .recenter])
        // Drain the recenter write from that press.
        XCTAssertEqual(logic.volumeChanged(from: 0.55, to: 0.5, at: 1.05), [])
        // Now a real press sequence ending exactly on 0.5:
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 2.0), [.pressUp, .recenter])
        XCTAssertEqual(logic.pendingRecenters, 1)
        // Down-press fires BEFORE the recenter write lands: 0.55 → 0.50.
        // Counter swallows it as the recenter echo (documented narrow
        // limitation), then the real recenter write fires no event (already
        // 0.5) — counter must not strand.
        XCTAssertEqual(logic.volumeChanged(from: 0.55, to: 0.5, at: 2.3), [])
        XCTAssertEqual(logic.pendingRecenters, 0)
        // Next press classifies normally — detection alive.
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.45, at: 3.0), [.pressDown, .recenter])
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
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0), [.pressUp, .recenter])
        // 100 ms later (Control Center drag / OS-coalesced burst): no press,
        // and no duplicate recenter while one is outstanding.
        XCTAssertEqual(logic.volumeChanged(from: 0.55, to: 0.6, at: 1.1), [])
        XCTAssertEqual(logic.pendingRecenters, 1)
    }

    func testEventAfterWindowPressesAgain() {
        var logic = engagedLogic()
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0), [.pressUp, .recenter])
        XCTAssertEqual(logic.volumeChanged(from: 0.55, to: 0.5, at: 1.1), [])   // recenter echo drains
        XCTAssertEqual(logic.volumeChanged(from: 0.5, to: 0.55, at: 1.3), [.pressUp, .recenter])
    }

    // MARK: - Re-center counter bookkeeping

    func testCounterNeverExceedsOne() {
        var logic = engagedLogic()
        _ = logic.volumeChanged(from: 0.5, to: 0.55, at: 1.0)   // press, recenter → 1
        _ = logic.volumeChanged(from: 0.55, to: 0.6, at: 1.05)  // coalesced, counter stays 1
        _ = logic.volumeChanged(from: 0.6, to: 0.65, at: 1.1)   // coalesced, counter stays 1
        XCTAssertEqual(logic.pendingRecenters, 1)
        // Single recenter write echo drains it fully.
        XCTAssertEqual(logic.volumeChanged(from: 0.65, to: 0.5, at: 1.2), [])
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

    func testStaleRestoreAcceptsBoundaries() {
        XCTAssertEqual(VolumeRockerLogic.staleRestoreVolume(persisted: 0.0), 0.0)
        XCTAssertEqual(VolumeRockerLogic.staleRestoreVolume(persisted: 1.0), 1.0)
    }
}
