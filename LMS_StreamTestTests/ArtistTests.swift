import XCTest
@testable import LMS_StreamTest

final class ArtistTests: XCTestCase {

    func testParseLoopHappyPath() {
        let raw: [[String: Any]] = [
            [
                "id": 1234,
                "artist": "Miles Davis"
            ],
            [
                "id": "5678",
                "artist": "Radiohead"
            ]
        ]

        let artists = Artist.parseLoop(raw)

        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists[0].id, "1234")
        XCTAssertEqual(artists[0].name, "Miles Davis")
        XCTAssertNil(artists[0].albumCount, "parseLoop never populates albumCount; only the search-results shape, not the artist-detail shape")
        XCTAssertEqual(artists[1].id, "5678", "id arrives as numeric String from some LMS endpoints")
        XCTAssertEqual(artists[1].name, "Radiohead")
    }

    func testParseLoopMissingId() {
        let raw: [[String: Any]] = [
            [
                "artist": "Orphan Artist"
            ]
        ]

        let artists = Artist.parseLoop(raw)

        XCTAssertEqual(artists.count, 0, "missing id is dropped (no way to playlistcontrol artist_id:N)")
    }

    func testParseLoopMissingName() {
        let raw: [[String: Any]] = [
            [
                "id": 42
            ]
        ]

        let artists = Artist.parseLoop(raw)

        XCTAssertEqual(artists.count, 0, "missing 'artist' field is dropped (nothing to display)")
    }

    func testParseLoopEmptyName() {
        let raw: [[String: Any]] = [
            [
                "id": 99,
                "artist": ""
            ]
        ]

        let artists = Artist.parseLoop(raw)

        XCTAssertEqual(artists.count, 0, "empty name is treated like missing — search results need something to render")
    }

    func testParseLoopEmptyInput() {
        XCTAssertEqual(Artist.parseLoop([]).count, 0)
    }

    func testParseLoopSkipsMalformedKeepsRest() {
        let raw: [[String: Any]] = [
            ["id": 1, "artist": "Good"],
            ["artist": "BadNoId"],  // skipped
            ["id": 3, "artist": "Also Good"]
        ]

        let artists = Artist.parseLoop(raw)

        XCTAssertEqual(artists.count, 2)
        XCTAssertEqual(artists[0].name, "Good")
        XCTAssertEqual(artists[1].name, "Also Good")
    }
}
