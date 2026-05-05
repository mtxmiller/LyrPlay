import XCTest
@testable import LMS_StreamTest

final class PlaylistTrackTests: XCTestCase {

    func testParseLoopHappyPath() {
        let raw: [[String: Any]] = [
            [
                "id": 1234,
                "title": "Black Star",
                "artist": "Radiohead",
                "album": "The Bends",
                "duration": 244.0,
                "tracknum": 6,
                "coverid": "abc123",
                "playlist index": 0
            ],
            [
                "id": "5678",
                "title": "Lucky",
                "artist": "Radiohead",
                "album": "OK Computer",
                "duration": 259.0,
                "tracknum": 11,
                "coverid": "def456",
                "playlist index": 1
            ]
        ]

        let tracks = PlaylistTrack.parseLoop(raw)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].id, "1234")
        XCTAssertEqual(tracks[0].title, "Black Star")
        XCTAssertEqual(tracks[0].artist, "Radiohead")
        XCTAssertEqual(tracks[0].album, "The Bends")
        XCTAssertEqual(tracks[0].duration, 244.0)
        XCTAssertEqual(tracks[0].trackNumber, 6)
        XCTAssertEqual(tracks[0].artworkURL, "abc123")
        XCTAssertEqual(tracks[0].playlistIndex, 0)
        XCTAssertEqual(tracks[1].id, "5678")
        XCTAssertEqual(tracks[1].title, "Lucky")
        XCTAssertEqual(tracks[1].playlistIndex, 1)
    }

    func testParseLoopMissingArtist() {
        let raw: [[String: Any]] = [
            [
                "id": 1,
                "title": "Untitled",
                "duration": 120.0,
                "playlist index": 0
            ]
        ]

        let tracks = PlaylistTrack.parseLoop(raw)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].title, "Untitled")
        XCTAssertNil(tracks[0].artist)
        XCTAssertNil(tracks[0].album)
    }

    func testParseLoopUuidFallbackPreservesUnparseableIds() {
        let raw: [[String: Any]] = [
            [
                "id": 1,
                "title": "Good Track",
                "artist": "Artist A",
                "playlist index": 0
            ],
            [
                // Malformed: id holds an unsupported type (array). Decoder fails for this entry.
                "id": ["not", "a", "string", "or", "int"],
                "title": "Bad Track"
            ],
            [
                "id": 3,
                "title": "Another Good Track",
                "artist": "Artist C",
                "playlist index": 2
            ]
        ]

        let tracks = PlaylistTrack.parseLoop(raw)

        XCTAssertEqual(tracks.count, 3, "Decoder falls back to UUID for unparseable id; entry is preserved")
        XCTAssertEqual(tracks[0].title, "Good Track")
        XCTAssertEqual(tracks[1].title, "Bad Track")
        XCTAssertEqual(tracks[2].title, "Another Good Track")
    }

    func testParseLoopEmptyInput() {
        XCTAssertEqual(PlaylistTrack.parseLoop([]).count, 0)
    }

    func testParseLoopDurationAsString() {
        let raw: [[String: Any]] = [
            [
                "id": 1,
                "title": "String Duration Track",
                "duration": "180.5",
                "playlist index": 0
            ]
        ]

        let tracks = PlaylistTrack.parseLoop(raw)

        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].duration, 180.5, "PlaylistTrack decoder accepts duration as both Double and String")
    }
}
