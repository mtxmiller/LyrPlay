import XCTest
@testable import LMS_StreamTest

/// Locks in CLAUDE.md rule #11: ICY metadata must NOT be pushed to LMS for
/// duration=0 (infinite radio) streams. Doing so crashes LMS XMLBrowser.pm
/// at line 1975 ("Can't call method 'duration' on an undefined value").
///
/// If a future change accidentally removes the duration gate in
/// `handleICYMetadata`, this test fails before it can ship.
final class SlimProtoICYMetadataTests: XCTestCase {

    func testRuleEleven_durationZero_doesNotSendToLMS() {
        XCTAssertFalse(
            SlimProtoCoordinator.shouldSendICYToLMS(streamDuration: 0.0),
            "Rule #11: sending ICY for duration=0 crashes LMS XMLBrowser.pm"
        )
    }

    func testRuleEleven_durationPositive_sendsToLMS() {
        XCTAssertTrue(
            SlimProtoCoordinator.shouldSendICYToLMS(streamDuration: 180.0),
            "File streams with known duration can safely receive ICY META"
        )
    }

    func testRuleEleven_durationNegative_doesNotSendToLMS() {
        // Defensive: getDuration() returning negative is unexpected but
        // should be treated the same as 0 (don't send).
        XCTAssertFalse(
            SlimProtoCoordinator.shouldSendICYToLMS(streamDuration: -1.0),
            "Negative duration is invalid; treat as duration=0"
        )
    }
}
