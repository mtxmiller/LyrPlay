import XCTest
@testable import LMS_StreamTest

final class PeakTrackerTests: XCTestCase {

    // MARK: - Initialization

    func testInitializesWithZeroPeaks() {
        let t = PeakTracker(bandCount: 64)
        XCTAssertEqual(t.peaks.count, 64)
        XCTAssertTrue(t.peaks.allSatisfy { $0 == 0 })
    }

    func testBandCountChangeReinitializesBuffer() {
        // Structs are value-typed, so "re-init" is just constructing a new tracker.
        // Verify both sizes produce the right buffer + survive an update.
        var t64 = PeakTracker(bandCount: 64)
        t64.update(bins: Array(repeating: 0.5, count: 64))
        XCTAssertEqual(t64.peaks.count, 64)
        XCTAssertTrue(t64.peaks.allSatisfy { $0 == 0.5 })

        var t32 = PeakTracker(bandCount: 32)
        XCTAssertEqual(t32.peaks.count, 32)
        t32.update(bins: Array(repeating: 0.3, count: 32))
        XCTAssertTrue(t32.peaks.allSatisfy { $0 == 0.3 })
    }

    // MARK: - Rise behavior (peaks snap instantly to new max)

    func testRiseSnapsInstantToNewMax() {
        var t = PeakTracker(bandCount: 4)
        t.update(bins: [0.5, 0.0, 0.3, 0.0])
        XCTAssertEqual(t.peaks, [0.5, 0.0, 0.3, 0.0])
    }

    func testHigherBinOverwritesEvenIfPreviousNonZero() {
        // Rise must win over decay: an incoming higher bin wholly replaces the
        // stored peak (no smoothing on the way up).
        var t = PeakTracker(bandCount: 1, decayPerFrame: 0.05)
        t.update(bins: [0.3])
        XCTAssertEqual(t.peaks[0], 0.3, accuracy: 1e-6)
        t.update(bins: [0.7])
        XCTAssertEqual(t.peaks[0], 0.7, accuracy: 1e-6)
    }

    // MARK: - Decay behavior

    func testDecayReducesByDecayPerFrame() {
        var t = PeakTracker(bandCount: 1, decayPerFrame: 0.1)
        t.update(bins: [0.5])               // rise
        t.update(bins: [0.0])               // decay one frame
        XCTAssertEqual(t.peaks[0], 0.4, accuracy: 1e-6)
        t.update(bins: [0.0])               // decay another frame
        XCTAssertEqual(t.peaks[0], 0.3, accuracy: 1e-6)
    }

    func testDecayFloorsAtZero() {
        // If decayPerFrame would push the peak negative, floor at 0 instead.
        var t = PeakTracker(bandCount: 1, decayPerFrame: 0.5)
        t.update(bins: [0.3])               // peak = 0.3
        t.update(bins: [0.0])               // 0.3 - 0.5 = -0.2 → floor to 0
        XCTAssertEqual(t.peaks[0], 0.0)
    }

    func testStableSilenceDecaysToZero() {
        // Multi-frame integration check: starting from a peak and feeding silence
        // for enough frames, peak settles cleanly at 0 (no oscillation, no NaN).
        var t = PeakTracker(bandCount: 1, decayPerFrame: 0.1)
        t.update(bins: [0.5])               // peak = 0.5
        for _ in 0..<10 {
            t.update(bins: [0.0])
        }
        XCTAssertEqual(t.peaks[0], 0.0)
    }

    // MARK: - Reset (called on pause/resume + preset-swap-to-Winamp)

    func testResetZeroesAllPeaks() {
        var t = PeakTracker(bandCount: 4)
        t.update(bins: [0.5, 0.3, 0.7, 0.1])
        XCTAssertFalse(t.peaks.allSatisfy { $0 == 0 })
        t.reset()
        XCTAssertTrue(t.peaks.allSatisfy { $0 == 0 })
    }

    // MARK: - Defensive: bin count mismatch (graceful, no crash)

    func testUpdateGracefulWhenBinsShorterThanTracker() {
        var t = PeakTracker(bandCount: 8)
        // Feed only 3 bins → first 3 update, remaining 5 stay at 0
        t.update(bins: [0.4, 0.5, 0.6])
        XCTAssertEqual(Array(t.peaks.prefix(3)), [0.4, 0.5, 0.6])
        XCTAssertTrue(t.peaks.suffix(5).allSatisfy { $0 == 0 })
    }

    func testUpdateGracefulWhenBinsLongerThanTracker() {
        var t = PeakTracker(bandCount: 3)
        // Feed 8 bins → first 3 update, extras ignored
        t.update(bins: [0.4, 0.5, 0.6, 9.9, 9.9, 9.9, 9.9, 9.9])
        XCTAssertEqual(t.peaks, [0.4, 0.5, 0.6])
    }
}
