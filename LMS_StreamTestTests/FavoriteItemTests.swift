import XCTest
@testable import LMS_StreamTest

final class FavoriteItemTests: XCTestCase {

    func testParseLoopHappyPath() {
        let raw: [[String: Any]] = [
            [
                "id": "stream:1",
                "name": "BBC Radio 3",
                "url": "http://stream.live.vc.bbcmedia.co.uk/bbc_radio_three",
                "image": "/imageproxy/bbc-radio-3.png",
                "type": "audio",
                "isaudio": 1
            ],
            [
                "id": 42,  // numeric id (LMS dual shape)
                "name": "Hey Jude",
                "url": "file:///music/Beatles/HeyJude.flac",
                "icon": "/music/12345/cover.jpg",
                "type": "audio",
                "isaudio": 1
            ]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "stream:1")
        XCTAssertEqual(items[0].name, "BBC Radio 3")
        XCTAssertEqual(items[0].url, "http://stream.live.vc.bbcmedia.co.uk/bbc_radio_three")
        XCTAssertEqual(items[0].icon, "/imageproxy/bbc-radio-3.png", "uses 'image' key when present")
        XCTAssertEqual(items[0].type, "audio")
        XCTAssertTrue(items[0].isAudio)
        XCTAssertEqual(items[1].id, "42", "numeric id coerced to String")
        XCTAssertEqual(items[1].icon, "/music/12345/cover.jpg", "falls back to 'icon' key when 'image' missing")
    }

    func testParseLoopFiltersFolderItems() {
        let raw: [[String: Any]] = [
            [
                "id": "track-1",
                "name": "Playable Track",
                "url": "file:///x.flac",
                "isaudio": 1
            ],
            [
                "id": "folder-1",
                "name": "Spotty",
                "hasitems": 1  // folder item — must be filtered
            ],
            [
                "id": "folder-2",
                "name": "BBC Sounds",
                "url": "",        // empty url + hasitems
                "hasitems": "1"   // String shape
            ],
            [
                "id": "track-2",
                "name": "Another Playable",
                "url": "file:///y.flac",
                "isaudio": 1
            ]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 2, "folder items (hasitems=1) are dropped in v1 — see LMS_StreamTest-5bs for v2 drill-down")
        XCTAssertEqual(items[0].name, "Playable Track")
        XCTAssertEqual(items[1].name, "Another Playable")
    }

    func testParseLoopFiltersMissingOrEmptyUrl() {
        let raw: [[String: Any]] = [
            [
                "id": "1",
                "name": "Has URL",
                "url": "http://example.com/stream"
            ],
            [
                "id": "2",
                "name": "Empty URL"
                // url field missing entirely
            ],
            [
                "id": "3",
                "name": "Empty String URL",
                "url": ""
            ]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 1, "items without a non-empty playable URL are dropped")
        XCTAssertEqual(items[0].name, "Has URL")
    }

    func testParseLoopFallsBackToTitleField() {
        let raw: [[String: Any]] = [
            [
                "id": "1",
                "title": "Title-Field Stream",  // 'title' instead of 'name'
                "url": "http://example.com/x"
            ]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Title-Field Stream", "falls back to 'title' when 'name' is missing")
    }

    func testParseLoopHandlesIsaudioStringShape() {
        let raw: [[String: Any]] = [
            ["id": "1", "name": "Int isaudio", "url": "x", "isaudio": 1],
            ["id": "2", "name": "String isaudio", "url": "y", "isaudio": "1"],
            ["id": "3", "name": "Missing isaudio", "url": "z"]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].isAudio)
        XCTAssertTrue(items[1].isAudio, "isaudio accepts both Int and String shape")
        XCTAssertFalse(items[2].isAudio, "missing isaudio defaults to false")
    }

    func testParseLoopMissingId() {
        let raw: [[String: Any]] = [
            ["name": "Orphan", "url": "http://example.com/x"]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 0, "missing id is dropped (no way to issue tap-to-play)")
    }

    func testParseLoopEmptyInput() {
        XCTAssertEqual(FavoriteItem.parseLoop([]).count, 0)
    }
}
