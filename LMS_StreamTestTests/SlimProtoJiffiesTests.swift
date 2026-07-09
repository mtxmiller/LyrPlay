import XCTest
@testable import LMS_StreamTest

/// Locks in the fix for bd LMS_StreamTest-7a8: jiffies (system uptime in ms,
/// sent in every STAT packet) must wrap at UInt32.max like squeezelite's
/// gettime_ms. The old `UInt32(uptime * 1000)` conversion trapped once device
/// uptime exceeded ~49.7 days, crashing the app on every STAT send — 21 of 26
/// App Store crash logs in 1.7.6–1.7.8 were this one bug.
final class SlimProtoJiffiesTests: XCTestCase {

    func testNormalUptime_convertsToMilliseconds() {
        XCTAssertEqual(SlimProtoClient.jiffies(uptimeSeconds: 0), 0)
        XCTAssertEqual(SlimProtoClient.jiffies(uptimeSeconds: 1.5), 1500)
        // 10 days
        XCTAssertEqual(SlimProtoClient.jiffies(uptimeSeconds: 864_000), 864_000_000)
    }

    func testUptimeBeyond49Days_wrapsInsteadOfTrapping() {
        // 60 days of uptime = 5_184_000_000 ms, past UInt32.max (4_294_967_295).
        // The old code trapped here (Swift runtime failure: Double value cannot
        // be converted to UInt32); the fix wraps modulo 2^32.
        let sixtyDays: TimeInterval = 60 * 24 * 60 * 60
        let expected = UInt32(UInt64(sixtyDays * 1000) % (UInt64(UInt32.max) + 1))
        XCTAssertEqual(SlimProtoClient.jiffies(uptimeSeconds: sixtyDays), expected)
    }

    func testUptimeExactlyAtWrapBoundary_wrapsToZero() {
        let boundarySeconds = (Double(UInt32.max) + 1) / 1000.0
        XCTAssertEqual(SlimProtoClient.jiffies(uptimeSeconds: boundarySeconds), 0)
    }

    func testVeryLongUptime_stillDoesNotTrap() {
        // A year of uptime — absurd but must not crash.
        let oneYear: TimeInterval = 365 * 24 * 60 * 60
        _ = SlimProtoClient.jiffies(uptimeSeconds: oneYear)
    }
}
