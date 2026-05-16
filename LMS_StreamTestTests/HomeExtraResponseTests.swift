import XCTest
@testable import LMS_StreamTest

/// Tests for `HomeExtraResponse.parse` — the tvOS Library tab's primary-path
/// router input. Verifies the Material `home-extra` JSON-RPC response shape
/// against Plugin.pm references (see HomeExtraResponse extension for line
/// numbers).
final class HomeExtraResponseTests: XCTestCase {

    // MARK: - Happy path

    func testParseHappyPath() {
        // Five shelves — favorites intentionally excluded in v1 (Jive-shape
        // parser not in v1; favorites reachable via the fallback path).
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_new_loop": [
                ["id": 1234, "album": "Kind of Blue", "artist": "Miles Davis", "artwork_track_id": "abc", "year": 1959],
                ["id": 5678, "album": "OK Computer", "artist": "Radiohead", "artwork_track_id": "def", "year": 1997]
            ],
            "material_home_recentlyplayed_loop": [
                ["id": 9999, "album": "Ghosts", "artist": "Hania Rani", "artwork_track_id": "ghi", "year": 2023]
            ],
            "material_home_artists_new_loop": [
                ["id": 42, "artist": "Sufjan Stevens"]
            ],
            "material_home_playlists_loop": [
                ["id": "100", "playlist": "Road Trip", "trackcount": 25]
            ],
            "material_home_radios_loop": [
                ["id": "radio:1", "name": "BBC Radio 3", "url": "http://stream.bbc.example/r3", "isaudio": 1]
            ]
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertTrue(parsed.materialInstalled)
        XCTAssertEqual(parsed.sections.count, 5, "five requested shelves populated → five sections")

        // Order matches HomeExtraResponse's albumSorts / artistSorts arrays then playlists / radios
        XCTAssertEqual(parsed.sections[0].id, "new")
        XCTAssertEqual(parsed.sections[0].title, "New Music")
        if case .albums(let albums) = parsed.sections[0].items {
            XCTAssertEqual(albums.count, 2)
            XCTAssertEqual(albums[0].name, "Kind of Blue")
        } else {
            XCTFail("first section should carry albums payload")
        }

        XCTAssertEqual(parsed.sections[1].id, "recentlyplayed")
        XCTAssertEqual(parsed.sections[2].id, "artists_new")
        if case .artists(let artists) = parsed.sections[2].items {
            XCTAssertEqual(artists.first?.name, "Sufjan Stevens")
        } else {
            XCTFail("artist section should carry artists payload")
        }

        XCTAssertEqual(parsed.sections[3].id, "playlists")
        XCTAssertEqual(parsed.sections[4].id, "radios")
    }

    func testParseIgnoresFavoritesObjInV1() {
        // Live server returns favorites in Jive-shape `material_home_favorites_obj.item_loop`,
        // not the simple FavoriteItem shape (verified against 192.168.1.8).
        // v1 doesn't parse favorites at all — even when the obj is present,
        // it must not produce a section. v2 will add Jive base+commonParams
        // parsing for plugin items.
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_favorites_obj": [
                "item_loop": [
                    ["text": "BBC Radio 3", "icon": "/img/r3.png", "actions": ["go": ["cmd": ["favorites", "items"]]]]
                ]
            ]
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertTrue(parsed.materialInstalled)
        XCTAssertTrue(parsed.sections.isEmpty, "favorites_obj is silently dropped in v1")
    }

    // MARK: - Routing flag

    func testParseMaterialNotInstalled_missingFlag() {
        // No `material_home` key at all → vanilla LMS (no Material plugin).
        let raw: [String: Any] = [
            "material_home_new_loop": [["id": 1, "album": "X", "artist": "Y"]]  // would be ignored
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertFalse(parsed.materialInstalled, "absence of material_home flag is the no-Material signal")
        XCTAssertTrue(parsed.sections.isEmpty, "no sections returned when flag absent — caller routes to BrowseLibraryView")
    }

    func testParseMaterialNotInstalled_flagZero() {
        let raw: [String: Any] = ["material_home": 0]
        let parsed = HomeExtraResponse.parse(raw)
        XCTAssertFalse(parsed.materialInstalled)
        XCTAssertTrue(parsed.sections.isEmpty)
    }

    func testParseMaterialInstalledButEmpty() {
        // Material is installed (flag present) but the library has no content.
        // Caller distinguishes this from "no Material" by checking materialInstalled.
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_new_loop": [],
            "material_home_recentlyplayed_loop": []
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertTrue(parsed.materialInstalled, "flag present → Material is loaded")
        XCTAssertTrue(parsed.sections.isEmpty, "all loops empty → no shelves; caller shows 'library is empty' state")
    }

    func testParseNumericFlag_stringForm() {
        // LMS sometimes serializes scalar 1 as String "1" depending on transport.
        let raw: [String: Any] = [
            "material_home": "1",
            "material_home_new_loop": [["id": 1, "album": "A", "artist": "B"]]
        ]
        let parsed = HomeExtraResponse.parse(raw)
        XCTAssertTrue(parsed.materialInstalled, "string '1' must be treated as installed")
        XCTAssertEqual(parsed.sections.count, 1)
    }

    // MARK: - Empty-loop filtering

    func testParseFiltersEmptyLoops() {
        // Mixed empty and populated loops — populated ones come through in order,
        // empty ones drop out so SwiftUI never renders bare headers.
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_new_loop": [["id": 1, "album": "A", "artist": "B"]],
            "material_home_recentlyplayed_loop": [],   // empty — must be dropped
            "material_home_random_loop": [["id": 2, "album": "C", "artist": "D"]],
            "material_home_popular_loop": []           // empty — must be dropped
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertEqual(parsed.sections.count, 2)
        XCTAssertEqual(parsed.sections.map(\.id), ["new", "random"])
    }

    // MARK: - @idx suffix stripping (Plugin.pm:2295)

    func testParseStripsIdxSuffixFromAlbums() {
        // Plugin.pm rewrites album.id to "<id>@idxN" so the same album can
        // appear in multiple sorts without duplicate-key issues. tap-to-play
        // must dispatch with the clean id (album_id:1234, not 1234@idx0).
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_new_loop": [
                ["id": "1234@idx0", "album": "Kind of Blue", "artist": "Miles Davis"],
                ["id": "5678@idx1", "album": "OK Computer", "artist": "Radiohead"]
            ]
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertEqual(parsed.sections.count, 1)
        if case .albums(let albums) = parsed.sections[0].items {
            XCTAssertEqual(albums[0].id, "1234", "@idx0 suffix stripped")
            XCTAssertEqual(albums[1].id, "5678", "@idx1 suffix stripped")
        } else {
            XCTFail("expected albums payload")
        }
    }

    func testParseStripsIdxSuffixFromArtists() {
        // Plugin.pm:2203 passes $idmod for artists too — same suffix rewrite applies.
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_artists_new_loop": [
                ["id": "42@idx0", "artist": "Sufjan Stevens"],
                ["id": "99@idx1", "artist": "Hania Rani"]
            ]
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertEqual(parsed.sections.count, 1)
        if case .artists(let artists) = parsed.sections[0].items {
            XCTAssertEqual(artists[0].id, "42")
            XCTAssertEqual(artists[1].id, "99")
        } else {
            XCTFail("expected artists payload")
        }
    }

    func testParseLeavesCleanIdsAlone() {
        // Playlists, radios, favorites are NOT suffix-rewritten by Plugin.pm
        // (they pass $idmod=undef). Their ids must come through unchanged.
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_playlists_loop": [
                ["id": "100", "playlist": "Road Trip"]
            ],
            "material_home_radios_loop": [
                ["id": "radio:1", "name": "BBC R3", "url": "http://x", "isaudio": 1]
            ]
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertEqual(parsed.sections.count, 2)
        if case .playlists(let pls) = parsed.sections[0].items {
            XCTAssertEqual(pls.first?.id, "100", "playlist ids never have @idx suffix")
        } else {
            XCTFail("expected playlists payload at index 0")
        }
        if case .favorites(let radios) = parsed.sections[1].items {
            XCTAssertEqual(radios.first?.id, "radio:1", "radio ids preserved exactly")
        } else {
            XCTFail("expected favorites payload at index 1")
        }
    }

    // MARK: - Radios via FavoriteItem shape

    func testParseRadiosViaFavoriteShape() {
        // Plugin.pm:2218 returns radios in `material_home_radios_loop` using the
        // FavoriteItem wire shape (id/name/url/icon/type/isaudio), NOT the
        // Album shape. Verify routing.
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_radios_loop": [
                ["id": "stream:1", "name": "BBC Radio 3", "url": "http://stream.example/r3", "image": "/img/r3.png", "type": "audio", "isaudio": 1],
                ["id": "stream:2", "name": "FIP", "url": "http://stream.example/fip", "icon": "/img/fip.png", "type": "audio", "isaudio": 1]
            ]
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertEqual(parsed.sections.count, 1)
        XCTAssertEqual(parsed.sections[0].id, "radios")
        if case .favorites(let radios) = parsed.sections[0].items {
            XCTAssertEqual(radios.count, 2)
            XCTAssertEqual(radios[0].name, "BBC Radio 3")
            XCTAssertEqual(radios[0].icon, "/img/r3.png", "image key preferred over icon when both present")
            XCTAssertEqual(radios[1].icon, "/img/fip.png", "falls back to icon key when image absent")
        } else {
            XCTFail("expected favorites (radios share that shape)")
        }
    }

    // MARK: - Radios URL-as-id synthesis (live server reality)

    func testParseRadiosSynthesizesIdFromUrl() {
        // Verified against 192.168.1.8 home server 2026-05-15:
        // `material-skin-query radios` (called by home-extra) returns radio
        // items WITHOUT a top-level `id` field — fields are just
        // {name,url,icon,ihe}. FavoriteItem.parseLoop requires id, so the
        // home-extra parser pre-processes radios to set id := url. The
        // synthesized id then drives HomeExtraShelf's dispatch — for the
        // radios shelf specifically it's used as the URL in
        // ["playlist","play",url] rather than as an item_id.
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_radios_loop": [
                ["name": "Bannon`s War Room", "url": "https://listen.warroom.org/feed.xml", "icon": "/imageproxy/x.png", "ihe": 1],
                ["name": "FIP", "url": "http://stream.example/fip.mp3", "icon": "/img/fip.png", "ihe": 1]
            ]
        ]

        let parsed = HomeExtraResponse.parse(raw)

        XCTAssertEqual(parsed.sections.count, 1)
        XCTAssertEqual(parsed.sections[0].id, "radios")
        if case .favorites(let radios) = parsed.sections[0].items {
            XCTAssertEqual(radios.count, 2, "both items survive despite missing wire id")
            XCTAssertEqual(radios[0].id, "https://listen.warroom.org/feed.xml",
                           "synthesized id IS the url — HomeExtraShelf uses it as the play-URL payload")
            XCTAssertEqual(radios[0].name, "Bannon`s War Room")
            XCTAssertEqual(radios[0].url, "https://listen.warroom.org/feed.xml")
            XCTAssertEqual(radios[1].id, "http://stream.example/fip.mp3")
        } else {
            XCTFail("expected favorites payload (radios reuse that case)")
        }
    }

    func testParseRadiosLeavesExplicitIdsAlone() {
        // If a server returns radios WITH an id field (some plugin versions
        // do, or v2-shape responses), keep the explicit id rather than
        // overwriting with url. Synthesis is a fallback, not a force.
        let raw: [String: Any] = [
            "material_home": 1,
            "material_home_radios_loop": [
                ["id": "explicit:42", "name": "Radio A", "url": "http://x/a", "icon": "/i/a.png", "ihe": 1]
            ]
        ]

        let parsed = HomeExtraResponse.parse(raw)

        if case .favorites(let radios) = parsed.sections[0].items {
            XCTAssertEqual(radios[0].id, "explicit:42", "wire id wins; synthesis only fires when absent")
        } else {
            XCTFail("expected favorites payload")
        }
    }
}
