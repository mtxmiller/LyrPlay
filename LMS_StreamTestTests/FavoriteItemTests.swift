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
        XCTAssertEqual(items[0].icon, "/imageproxy/bbc-radio-3.png", "uses 'image' key when present")
        XCTAssertEqual(items[0].type, "audio")
        XCTAssertTrue(items[0].isAudio)
        XCTAssertFalse(items[0].isFolder, "playable audio is not a folder")
        XCTAssertEqual(items[1].id, "42", "numeric id coerced to String")
        XCTAssertEqual(items[1].icon, "/music/12345/cover.jpg", "falls back to 'icon' key when 'image' missing")
        XCTAssertFalse(items[1].isFolder)
    }

    // REGRESSION (k63): folders were dropped in v1; they are now RETAINED and
    // flagged isFolder so CarPlay can drill. Consumers that can't drill filter.
    func testParseLoopRetainsFoldersAndFlagsThem() {
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
                "hasitems": 1  // folder — retained, isFolder true
            ],
            [
                "id": "folder-2",
                "name": "BBC Sounds",
                "url": "",        // empty url + hasitems, String shape
                "hasitems": "1"
            ],
            [
                "id": "track-2",
                "name": "Another Playable",
                "url": "file:///y.flac",
                "isaudio": 1
            ]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 4, "folders are retained now, not dropped")
        XCTAssertEqual(items.map(\.name), ["Playable Track", "Spotty", "BBC Sounds", "Another Playable"])
        XCTAssertEqual(items.filter(\.isFolder).map(\.name), ["Spotty", "BBC Sounds"], "hasitems items flagged as folders")
        XCTAssertFalse(items[0].isFolder)
        XCTAssertFalse(items[3].isFolder)
    }

    // Verified on 192.168.1.8: podcast/OPML episodes come back hasitems:1 AND
    // isaudio:1 with no url. Those are PLAYABLE leaves, not folders — classifying
    // on hasitems alone would make every episode drill instead of play.
    func testPodcastEpisodeIsPlayableNotFolder() {
        let raw: [[String: Any]] = [
            [
                "id": "7208d7a2.0.0",
                "name": "Episode 5489",
                "hasitems": 1,
                "isaudio": 1
                // no url
            ]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 1, "audio-with-hasitems episode is kept via the isAudio gate")
        XCTAssertTrue(items[0].isAudio)
        XCTAssertFalse(items[0].isFolder, "hasitems AND isaudio -> playable leaf, not a folder")
    }

    // A real LMS folder can carry a url (verified: listen.warroom.org/feed.xml).
    // isFolder must derive from hasitems && !isAudio, NOT from url absence.
    func testFolderWithUrlIsStillFolder() {
        let raw: [[String: Any]] = [
            [
                "id": "7208d7a2.0",
                "name": "Bannon's War Room",
                "type": "link",
                "hasitems": 1,
                "isaudio": 0,
                "url": "https://listen.warroom.org/feed.xml"
            ]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isFolder, "hasitems && !isAudio -> folder even though it has a url")
    }

    // Keep-gate: hasitems OR isAudio OR non-empty url. A url-less, non-audio,
    // non-folder row (e.g. type:text separator) is dropped.
    func testUrlLessNonAudioNonFolderIsDropped() {
        let raw: [[String: Any]] = [
            ["id": "sep-1", "name": "— separator —", "type": "text"],
            ["id": "ok-1", "name": "Has URL", "url": "http://example.com/stream"]
        ]

        let items = FavoriteItem.parseLoop(raw)

        XCTAssertEqual(items.count, 1, "text/url-less non-audio non-folder rows are dropped")
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
