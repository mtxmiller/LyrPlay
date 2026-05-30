import XCTest
@testable import LMS_StreamTest

/// Tests for the plugin-shelf parser surface added in build 9:
/// `HomeExtraResponse.parseRegistry`, `HomeExtraResponse.parsePluginSections`,
/// `JiveItem.parseObj`, and `JiveItem` action resolution / dispatch.
///
/// Fixtures mirror the wire shapes verified live against 192.168.1.8 (3
/// Bandcamp plugin shelves) on 2026-05-19 — see the build-9 design doc.
final class JiveItemTests: XCTestCase {

    // MARK: - Registry (home-extra-3rdparty)

    func testParseRegistryHappyPath() {
        // result.items is a JSON-ENCODED STRING, not a JSON array.
        let result: [String: Any] = [
            "items": """
            [{"id":"3rdparty_Bandcampdaily","title":"Bandcamp Daily","subtitle":null,"icon":"plugins/Bandcamp/html/images/logo.png","needsPlayer":1}]
            """
        ]
        let registry = HomeExtraResponse.parseRegistry(result)
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry[0].id, "3rdparty_Bandcampdaily")
        XCTAssertEqual(registry[0].title, "Bandcamp Daily")
        XCTAssertNil(registry[0].subtitle)
        XCTAssertTrue(registry[0].needsPlayer)
    }

    func testParseRegistryStripsPrefix() {
        let result: [String: Any] = [
            "items": #"[{"id":"3rdparty_Bandcampdaily","title":"X"}]"#
        ]
        let registry = HomeExtraResponse.parseRegistry(result)
        // The `3rdparty_` prefix must be stripped for the home-extra param;
        // Plugin.pm:551 re-adds it on lookup.
        XCTAssertEqual(registry[0].strippedID, "Bandcampdaily")
        XCTAssertEqual(registry[0].shelfKey, "plugin:Bandcampdaily")
    }

    func testParseRegistryNeedsPlayerDefaultsFalse() {
        let result: [String: Any] = [
            "items": #"[{"id":"3rdparty_X","title":"X"}]"#
        ]
        XCTAssertFalse(HomeExtraResponse.parseRegistry(result)[0].needsPlayer)
    }

    func testParseRegistryMalformedJSON() {
        XCTAssertEqual(HomeExtraResponse.parseRegistry(["items": "not json"]).count, 0)
    }

    func testParseRegistryDropsEntriesMissingIdOrTitle() {
        let result: [String: Any] = [
            "items": #"[{"title":"no id"},{"id":"3rdparty_ok","title":"OK"},{"id":"3rdparty_notitle"}]"#
        ]
        let registry = HomeExtraResponse.parseRegistry(result)
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry[0].id, "3rdparty_ok")
    }

    func testStrippedIDPassThroughWhenNoPrefix() {
        let reg = PluginExtraRegistration(id: "Bandcampdaily", title: "X", subtitle: nil, icon: nil, needsPlayer: false)
        XCTAssertEqual(reg.strippedID, "Bandcampdaily")
    }

    // MARK: - Registry mojibake repair (LMS_StreamTest-51c)

    func testParseRegistryRepairsMojibakeTitleAndSubtitle() {
        // home-extra-3rdparty double-encodes: a German title arrives as UTF-8
        // bytes read as Latin-1 — "Hauptmenü" → "HauptmenÃ¼".
        let result: [String: Any] = [
            "items": #"[{"id":"3rdparty_Tidal","title":"HauptmenÃ¼","subtitle":"FÃ¼r dich"}]"#
        ]
        let registry = HomeExtraResponse.parseRegistry(result)
        XCTAssertEqual(registry[0].title, "Hauptmenü")
        XCTAssertEqual(registry[0].subtitle, "Für dich")
    }

    func testRepairingMojibakeIsIdempotent() {
        // Already-correct UTF-8 and pure ASCII must pass through unchanged.
        XCTAssertEqual("Hauptmenü".repairingMojibake(), "Hauptmenü")
        XCTAssertEqual("Bandcamp Daily".repairingMojibake(), "Bandcamp Daily")
    }

    // MARK: - parseObj — level-1 shape (items carry their own actions)

    func testParseObjItemDirectActions() {
        // Bandcamp level-1: items carry `actions.go`, no obj-level `base`.
        let obj: [String: Any] = [
            "item_loop": [
                [
                    "addAction": "go",
                    "text": "Spencer's Gifts",
                    "icon": "/imageproxy/x.jpg",
                    "actions": [
                        "go": [
                            "cmd": ["Bandcampdaily", "items"],
                            "params": ["menu": "Bandcampdaily", "item_id": "0"]
                        ]
                    ]
                ]
            ]
        ]
        let (base, items) = JiveItem.parseObj(obj)
        XCTAssertTrue(base.isEmpty)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Spencer's Gifts")
        XCTAssertEqual(items[0].addAction, "go")

        let resolved = items[0].resolvedAction(named: "go", base: base)
        XCTAssertEqual(resolved?.cmd, ["Bandcampdaily", "items"])
        XCTAssertEqual(resolved?.params["item_id"] as? String, "0")
    }

    // MARK: - parseObj — level-2 shape (base.actions + per-item params merge)

    func testParseObjBaseActionsMerge() {
        // Canonical SlimBrowse: obj-level base.actions is the template,
        // itemsParams names the per-item field to merge in.
        let obj: [String: Any] = [
            "base": [
                "actions": [
                    "go": [
                        "cmd": ["Bandcampdaily", "items"],
                        "params": ["menu": "Bandcampdaily"],
                        "itemsParams": "params"
                    ]
                ]
            ],
            "item_loop": [
                ["text": "Daily Show Tracks", "type": "playlist", "params": ["item_id": "0.0"]]
            ]
        ]
        let (base, items) = JiveItem.parseObj(obj)
        XCTAssertEqual(base.count, 1)
        XCTAssertEqual(items.count, 1)

        let resolved = items[0].resolvedAction(named: "go", base: base)
        XCTAssertEqual(resolved?.cmd, ["Bandcampdaily", "items"])
        // Base param survives, per-item param is merged in.
        XCTAssertEqual(resolved?.params["menu"] as? String, "Bandcampdaily")
        XCTAssertEqual(resolved?.params["item_id"] as? String, "0.0")
    }

    func testResolvedActionReturnsNilWhenNoAction() {
        let (base, items) = JiveItem.parseObj([
            "item_loop": [["text": "no actions"]]
        ])
        XCTAssertNil(items[0].resolvedAction(named: "go", base: base))
    }

    func testParseObjDropsItemMissingText() {
        let obj: [String: Any] = [
            "item_loop": [
                ["icon": "x.jpg"],                       // no text → dropped
                ["text": "valid"]
            ]
        ]
        let (_, items) = JiveItem.parseObj(obj)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "valid")
    }

    func testParseObjSynthesizesIDWhenAbsent() {
        let (_, items) = JiveItem.parseObj(["item_loop": [["text": "A"], ["text": "B"]]])
        // Distinct synthesized ids → SwiftUI ForEach identity holds.
        XCTAssertNotEqual(items[0].id, items[1].id)
    }

    func testParseObjEmptyLoop() {
        let (base, items) = JiveItem.parseObj([:])
        XCTAssertTrue(base.isEmpty)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - goAction / nextWindow (7do — wire-verified against Bandcamp)

    func testParseItemReadsGoActionAndNextWindow() {
        // Leaf-track wire shape: goAction:"play" + item-level nextWindow.
        let obj: [String: Any] = [
            "item_loop": [
                ["text": "Title Screen", "goAction": "play", "nextWindow": "nowPlaying",
                 "params": ["item_id": "0.0.1"]]
            ]
        ]
        let (_, items) = JiveItem.parseObj(obj)
        XCTAssertEqual(items[0].goAction, "play")
        XCTAssertEqual(items[0].tapActionName, "play")   // goAction drives the tap
        XCTAssertEqual(items[0].nextWindow, "nowPlaying")
    }

    func testTapAndAddActionNamesDefault() {
        let (_, items) = JiveItem.parseObj(["item_loop": [["text": "Folder"]]])
        XCTAssertEqual(items[0].tapActionName, "go")     // no goAction → "go"
        XCTAssertEqual(items[0].addActionName, "add")    // no addAction → "add"
    }

    func testParseActionsReadsNextWindow() {
        // Base `play` carries nextWindow (Bandcamp sends "nowPlaying").
        let obj: [String: Any] = [
            "base": ["actions": [
                "play": ["cmd": ["Bandcampdaily", "playlist", "play"],
                         "params": ["menu": "Bandcampdaily"],
                         "itemsParams": "params",
                         "nextWindow": "nowPlaying"]
            ]],
            "item_loop": [["text": "A track", "params": ["item_id": "0.0.0"]]]
        ]
        let (base, items) = JiveItem.parseObj(obj)
        let resolved = items[0].resolvedAction(named: "play", base: base)
        XCTAssertEqual(resolved?.cmd, ["Bandcampdaily", "playlist", "play"])
        // play.itemsParams == "params" → per-item params merge (the design's
        // load-bearing assumption — wire-confirmed).
        XCTAssertEqual(resolved?.params["item_id"] as? String, "0.0.0")
        XCTAssertEqual(resolved?.params["menu"] as? String, "Bandcampdaily")
        XCTAssertEqual(resolved?.nextWindow, "nowplaying")   // lowercased
    }

    func testItemNextWindowWinsOverActionNextWindow() {
        let obj: [String: Any] = [
            "base": ["actions": ["go": ["cmd": ["x", "items"], "nextWindow": "parent"]]],
            "item_loop": [["text": "A", "nextWindow": "Refresh"]]
        ]
        let (base, items) = JiveItem.parseObj(obj)
        // Item-level nextWindow wins over the action's, lowercased.
        XCTAssertEqual(items[0].resolvedAction(named: "go", base: base)?.nextWindow, "refresh")
    }

    // MARK: - ResolvedJiveAction.paramArgs (dispatch-helper request shape)

    func testParamArgsScalarAndNonScalar() {
        let action = ResolvedJiveAction(
            cmd: ["x"],
            params: ["item_id": "0.0", "menu": ["a", "b"]],
            nextWindow: nil
        )
        let args = action.paramArgs
        XCTAssertTrue(args.contains("item_id:0.0"))
        // A non-scalar value is JSON-encoded, not interpolated to garbage.
        XCTAssertTrue(args.contains { $0.hasPrefix("menu:[") })
        XCTAssertEqual(action.cliArgs.first, "x")
    }

    // MARK: - Regression guard (7do — drill vs play resolution)

    func testRegressionPlaylistItemResolvesGoAndPlay() {
        // A playlist-shaped item (no item-level actions) must resolve BOTH the
        // base `go` (drill) AND the base `play` — the build-9 dispatch bug
        // left a `type:"playlist"` item with no path to `play`.
        let obj: [String: Any] = [
            "base": ["actions": [
                "go":   ["cmd": ["P", "items"], "params": ["menu": "P"], "itemsParams": "params"],
                "play": ["cmd": ["P", "playlist", "play"], "params": ["menu": "P"],
                         "itemsParams": "params", "nextWindow": "nowPlaying"],
                "add":  ["cmd": ["P", "playlist", "add"], "params": ["menu": "P"], "itemsParams": "params"]
            ]],
            "item_loop": [["text": "A playlist", "type": "playlist", "params": ["item_id": "0.0"]]]
        ]
        let (base, items) = JiveItem.parseObj(obj)
        let item = items[0]
        XCTAssertNotNil(item.resolvedAction(named: "go", base: base))
        let play = item.resolvedAction(named: "play", base: base)
        XCTAssertEqual(play?.cmd, ["P", "playlist", "play"])
        XCTAssertEqual(play?.params["item_id"] as? String, "0.0")
        XCTAssertNotNil(item.resolvedAction(named: item.addActionName, base: base))
    }

    // MARK: - parsePluginSections

    func testParsePluginSectionsMatchesObjKeys() {
        let registry = [
            PluginExtraRegistration(id: "3rdparty_Bandcampdaily", title: "Bandcamp Daily",
                                    subtitle: nil, icon: "logo.png", needsPlayer: true)
        ]
        let result: [String: Any] = [
            "material_home_Bandcampdaily_obj": [
                "item_loop": [
                    ["text": "A", "actions": ["go": ["cmd": ["c", "items"], "params": [:]]]]
                ]
            ]
        ]
        let sections = HomeExtraResponse.parsePluginSections(result, registry: registry)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].id, "plugin:Bandcampdaily")
        XCTAssertEqual(sections[0].title, "Bandcamp Daily")
        XCTAssertEqual(sections[0].pluginIcon, "logo.png")
        if case .jive(_, let items) = sections[0].items {
            XCTAssertEqual(items.count, 1)
        } else {
            XCTFail("plugin section should carry a .jive payload")
        }
    }

    func testParsePluginSectionsSkipsMissingAndEmptyObjs() {
        let registry = [
            PluginExtraRegistration(id: "3rdparty_Present", title: "Present", subtitle: nil, icon: nil, needsPlayer: false),
            PluginExtraRegistration(id: "3rdparty_Absent", title: "Absent", subtitle: nil, icon: nil, needsPlayer: false),
            PluginExtraRegistration(id: "3rdparty_Empty", title: "Empty", subtitle: nil, icon: nil, needsPlayer: false)
        ]
        let result: [String: Any] = [
            "material_home_Present_obj": ["item_loop": [["text": "A", "actions": ["go": ["cmd": ["c"], "params": [:]]]]]],
            "material_home_Empty_obj": ["item_loop": []]   // present but empty → skipped
        ]
        let sections = HomeExtraResponse.parsePluginSections(result, registry: registry)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "Present")
    }

    // MARK: - LibraryShelf catalog (build 9 enrichment)

    func testLibraryShelfCatalogComplete() {
        // Every shelf must supply a title, subtitle, and SF Symbol — the
        // Settings picker renders all three.
        for shelf in LibraryShelf.allCases {
            XCTAssertFalse(shelf.title.isEmpty, "\(shelf) missing title")
            XCTAssertFalse(shelf.subtitle.isEmpty, "\(shelf) missing subtitle")
            XCTAssertFalse(shelf.iconSystemName.isEmpty, "\(shelf) missing icon")
        }
    }

}
