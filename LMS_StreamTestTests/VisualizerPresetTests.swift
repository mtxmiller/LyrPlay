import XCTest
@testable import LMS_StreamTest

final class VisualizerPresetTests: XCTestCase {

    // MARK: - Display names (overlay-facing strings)

    func testDisplayNameForEachCase() {
        XCTAssertEqual(VisualizerPreset.bloom.displayName,       "Bloom")
        XCTAssertEqual(VisualizerPreset.ledHiFi.displayName,     "LED Hi-Fi")
        XCTAssertEqual(VisualizerPreset.winamp.displayName,      "Winamp")
        XCTAssertEqual(VisualizerPreset.iTunesClean.displayName, "iTunes")
    }

    // MARK: - Forward cycle (RIGHT swipe)

    func testNextCyclesForwardWithWrap() {
        XCTAssertEqual(VisualizerPreset.bloom.next(),       .ledHiFi)
        XCTAssertEqual(VisualizerPreset.ledHiFi.next(),     .winamp)
        XCTAssertEqual(VisualizerPreset.winamp.next(),      .iTunesClean)
        // wrap: iTunesClean → bloom
        XCTAssertEqual(VisualizerPreset.iTunesClean.next(), .bloom)
    }

    // MARK: - Backward cycle (LEFT swipe)

    func testPreviousCyclesBackwardWithWrap() {
        // wrap: bloom → iTunesClean
        XCTAssertEqual(VisualizerPreset.bloom.previous(),       .iTunesClean)
        XCTAssertEqual(VisualizerPreset.iTunesClean.previous(), .winamp)
        XCTAssertEqual(VisualizerPreset.winamp.previous(),      .ledHiFi)
        XCTAssertEqual(VisualizerPreset.ledHiFi.previous(),     .bloom)
    }

    // MARK: - Persistence round-trip (@AppStorage Int <-> enum)

    func testRawValueRoundTripsForAllCases() {
        for preset in VisualizerPreset.allCases {
            XCTAssertEqual(VisualizerPreset(rawValue: preset.rawValue), preset)
        }
    }

    // MARK: - Invalid persisted value handling

    func testInitReturnsNilForInvalidRawValue() {
        XCTAssertNil(VisualizerPreset(rawValue: -1))
        XCTAssertNil(VisualizerPreset(rawValue: 4))
        XCTAssertNil(VisualizerPreset(rawValue: 100))
    }

    // MARK: - Enum stability guard

    func testAllCasesCountIsFour() {
        // Guards against accidental case reordering / addition / removal breaking
        // persisted @AppStorage values. If you add a NEW preset, bump this number
        // AND append at the end (never renumber existing cases).
        XCTAssertEqual(VisualizerPreset.allCases.count, 4)
    }

    func testRawValuesAreContiguousFromZero() {
        // Guards against accidental .case = 5 explicit assignment. Persistence
        // depends on 0..3 being stable forever.
        XCTAssertEqual(VisualizerPreset.bloom.rawValue,       0)
        XCTAssertEqual(VisualizerPreset.ledHiFi.rawValue,     1)
        XCTAssertEqual(VisualizerPreset.winamp.rawValue,      2)
        XCTAssertEqual(VisualizerPreset.iTunesClean.rawValue, 3)
    }
}
