import XCTest
@testable import LMS_StreamTest

/// Tests for `Playlist.parseLoop` static helper.
/// (The pre-existing Codable decoder is tested implicitly here too.)
final class PlaylistParseLoopTests: XCTestCase {

    func testParseLoopHappyPath() {
        let raw: [[String: Any]] = [
            [
                "id": 7,
                "playlist": "Workout",
                "trackcount": 24,
                "duration": 4800.0,
                "url": "playlist:workout",
                "modifiable": true
            ],
            [
                "id": "guest:42",
                "playlist": "Sunday Morning",
                "trackcount": 11,
                "modifiable": false
            ]
        ]

        let playlists = Playlist.parseLoop(raw)

        XCTAssertEqual(playlists.count, 2)
        XCTAssertEqual(playlists[0].id, "7")
        XCTAssertEqual(playlists[0].name, "Workout")
        XCTAssertEqual(playlists[0].trackCount, 24)
        XCTAssertEqual(playlists[0].duration, 4800.0)
        XCTAssertEqual(playlists[0].originalNumericId, 7, "numeric ids preserve their Int form for downstream `playlists tracks` calls")
        XCTAssertEqual(playlists[1].id, "guest:42")
        XCTAssertNil(playlists[1].originalNumericId, "non-numeric ids have no preserved Int form")
    }

    func testParseLoopMissingNameUsesDefault() {
        let raw: [[String: Any]] = [
            ["id": 1]
        ]

        let playlists = Playlist.parseLoop(raw)

        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists[0].name, "Unknown Playlist", "Codable defaults missing name")
    }

    func testParseLoopEmptyInput() {
        XCTAssertEqual(Playlist.parseLoop([]).count, 0)
    }

    func testParseLoopSkipsMalformedKeepsRest() {
        let raw: [[String: Any]] = [
            ["id": 1, "playlist": "Good"],
            ["id": ["not", "a", "string"], "playlist": "Survives via UUID fallback"],  // unparseable id → UUID fallback
            ["id": 3, "playlist": "Also Good"]
        ]

        let playlists = Playlist.parseLoop(raw)

        // Codable decoder falls back to UUID for unparseable id rather than throwing,
        // matching the PlaylistTrack pattern. So all three entries are returned.
        XCTAssertEqual(playlists.count, 3)
        XCTAssertEqual(playlists[0].name, "Good")
        XCTAssertEqual(playlists[2].name, "Also Good")
    }

    func testParseLoopMissingTrackCountIsNil() {
        let raw: [[String: Any]] = [
            ["id": 1, "playlist": "No Count Available"]
        ]

        let playlists = Playlist.parseLoop(raw)

        XCTAssertEqual(playlists.count, 1)
        XCTAssertNil(playlists[0].trackCount)
        XCTAssertEqual(playlists[0].trackCountDisplay, "", "trackCountDisplay returns empty string when count missing")
    }
}
