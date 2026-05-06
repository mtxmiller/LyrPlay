import XCTest
@testable import LMS_StreamTest

final class AlbumTests: XCTestCase {

    func testParseLoopHappyPath() {
        let raw: [[String: Any]] = [
            [
                "id": 1234,
                "album": "Kind of Blue",
                "artist": "Miles Davis",
                "artwork_track_id": "abc123",
                "year": 1959
            ],
            [
                "id": "5678",
                "album": "OK Computer",
                "artist": "Radiohead",
                "artwork_track_id": "def456",
                "year": "1997"  // LMS sometimes returns year as String
            ]
        ]

        let albums = Album.parseLoop(raw)

        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].id, "1234")
        XCTAssertEqual(albums[0].name, "Kind of Blue")
        XCTAssertEqual(albums[0].artist, "Miles Davis")
        XCTAssertEqual(albums[0].artworkTrackId, "abc123")
        XCTAssertEqual(albums[0].year, 1959)
        XCTAssertNil(albums[0].artwork, "parseLoop never populates artwork; consumer resolves via URL")
        XCTAssertEqual(albums[1].id, "5678")
        XCTAssertEqual(albums[1].year, 1997, "year arrives as String from some LMS versions")
    }

    func testParseLoopMissingArtist() {
        let raw: [[String: Any]] = [
            [
                "id": 1,
                "album": "Compilation",
                "artwork_track_id": "xyz"
            ]
        ]

        let albums = Album.parseLoop(raw)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].artist, "", "missing artist defaults to empty string (consumer decides display)")
    }

    func testParseLoopMissingArtwork() {
        let raw: [[String: Any]] = [
            [
                "id": 99,
                "album": "Lo-Fi",
                "artist": "Various"
            ]
        ]

        let albums = Album.parseLoop(raw)

        XCTAssertEqual(albums.count, 1)
        XCTAssertNil(albums[0].artworkTrackId, "missing artwork_track_id is nil (caller falls back to album.id for URL)")
    }

    func testParseLoopMissingId() {
        let raw: [[String: Any]] = [
            [
                "album": "Orphan Album",
                "artist": "Nobody"
            ]
        ]

        let albums = Album.parseLoop(raw)

        XCTAssertEqual(albums.count, 0, "missing id is dropped (no way to load it)")
    }

    func testParseLoopMissingName() {
        let raw: [[String: Any]] = [
            [
                "id": 42,
                "artist": "Has Artist No Name"
            ]
        ]

        let albums = Album.parseLoop(raw)

        XCTAssertEqual(albums.count, 0, "missing 'album' field is dropped (nothing to display)")
    }

    func testParseLoopEmptyInput() {
        XCTAssertEqual(Album.parseLoop([]).count, 0)
    }

    func testParseLoopSkipsMalformedKeepsRest() {
        let raw: [[String: Any]] = [
            ["id": 1, "album": "Good", "artist": "A"],
            ["album": "BadNoId"],  // skipped
            ["id": 3, "album": "Also Good", "artist": "B"]
        ]

        let albums = Album.parseLoop(raw)

        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums[0].name, "Good")
        XCTAssertEqual(albums[1].name, "Also Good")
    }
}
