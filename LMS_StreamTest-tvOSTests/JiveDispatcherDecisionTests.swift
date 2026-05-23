import Testing
import Foundation
@testable import LMS_StreamTest_tvOS

/// Tests for `JiveDispatcher.decide(item:base:)` — the round-4 / build-12
/// classifier composition. The shared-model predicates (`isPlayVerb`,
/// `hasLeafHint`) are unit-tested in `JiveItemClassifierTests` (shared target);
/// this file tests how the dispatcher *combines* them and resolves the
/// `.terminal` / `.drill` / `.unresolved` outcome.
///
/// Includes the four Bandcamp fixture-replay cases captured 2026-05-22 against
/// `192.168.1.8` — the wire data that drove the round-4 design (see
/// `wire-data-bandcamp-20260522.json`).
struct JiveDispatcherDecisionTests {

    // MARK: - Classifier composition

    @Test func leafTrackWithPlayCmd_classifiesTerminal() {
        // Bandcamp leaf: goAction:"play", style:"itemplay", base.play has
        // cmd:["...","playlist","play"] + nextWindow:"nowPlaying".
        let item = makeItem(
            goAction: "play",
            style: "itemplay",
            params: ["touchToPlay": "0.0.1"]
        )
        let base: [String: JiveItemAction] = [
            "play": JiveItemAction(
                cmd: ["Bandcampdaily", "playlist", "play"],
                params: ["menu": "Bandcampdaily"],
                itemsParams: "params",
                nextWindow: "nowPlaying"
            ),
        ]
        if case .terminal = JiveDispatcher.decide(item: item, base: base) {
            // pass
        } else {
            Issue.record("Expected .terminal for a leaf track with play cmd")
        }
    }

    @Test func playActionWithoutNextWindow_stillTerminal() {
        // THE gi0 BUG: a play action that doesn't carry nextWindow used to be
        // misclassified as a drill (the play cmd was re-fetched as if it were
        // a browse level, producing mherger's "refresh the menu" symptom).
        // The cmd-first classifier must classify this as terminal regardless.
        let item = makeItem(goAction: "play")
        let base: [String: JiveItemAction] = [
            "play": JiveItemAction(
                cmd: ["someplugin", "playlist", "play"],
                params: ["track_id": "42"],
                itemsParams: "params",
                nextWindow: nil  // ← the bug surface: no nextWindow
            ),
        ]
        if case .terminal = JiveDispatcher.decide(item: item, base: base) {
            // pass
        } else {
            Issue.record("Expected .terminal for play cmd without nextWindow (gi0 fix)")
        }
    }

    @Test func nextWindowNowplayingWithUnknownCmd_classifiesTerminal() {
        // E5 reinstated: nextWindow=="nowplaying" is a third terminal signal.
        // Useful when a plugin's play cmd shape the classifier doesn't
        // recognize but the server still tells us "this goes to Now Playing."
        let item = makeItem()
        let base: [String: JiveItemAction] = [
            "go": JiveItemAction(
                cmd: ["weirdplugin", "fancystart"],
                params: [:],
                itemsParams: nil,
                nextWindow: "nowPlaying"
            ),
        ]
        if case .terminal = JiveDispatcher.decide(item: item, base: base) {
            // pass
        } else {
            Issue.record("Expected .terminal when nextWindow==nowplaying (E5)")
        }
    }

    @Test func browseFolderItem_classifiesDrill() {
        // Plugin folder: no goAction → tap="go", base.go is browse cmd.
        let item = makeItem()
        let base: [String: JiveItemAction] = [
            "go": JiveItemAction(
                cmd: ["Bandcampdaily", "items"],
                params: ["item_id": "5"],
                itemsParams: "params",
                nextWindow: nil
            ),
        ]
        if case .drill(let cmd) = JiveDispatcher.decide(item: item, base: base) {
            #expect(cmd.cmd == ["Bandcampdaily", "items"])
            #expect(cmd.title == "Test Item")
        } else {
            Issue.record("Expected .drill for browse cmd with no leaf hints")
        }
    }

    @Test func containerWithLeafTypeHint_classifiesDrill() {
        // FALSE-POSITIVE GUARD: a container whose `cmd` is a browse verb but
        // which carries a leaf-ish `type` must still drill. cmd beats type.
        let item = makeItem(type: "audio")  // ← leaf-ish type
        let base: [String: JiveItemAction] = [
            "go": JiveItemAction(
                cmd: ["someplugin", "items"],  // ← browse verb
                params: [:],
                itemsParams: nil,
                nextWindow: nil
            ),
        ]
        if case .drill = JiveDispatcher.decide(item: item, base: base) {
            // pass
        } else {
            Issue.record("Expected .drill — browse cmd must beat leaf type hint (false-positive guard)")
        }
    }

    @Test func bandcampWeeklyTrack_classifiesTerminalViaBasePlay() {
        // Build-12 round-2 hardware bug: Bandcamp Weekly track-list items
        // carry goAction:"playControl". The playControl action resolves to a
        // BROWSE cmd (`[Bandcampweekly,items]` with isContextMenu=1 — opens a
        // context-menu window on Squeezebox Touch), but the item is clearly a
        // leaf (presetParams.favorites_url is present, favorites_type=audio).
        // base.play exists with the real play cmd. The classifier must
        // recognize the leaf hint AND prefer base.play over the playControl
        // browse cmd. Without this, tap drills into a useless level and the
        // track never plays.
        let item = makeItem(
            goAction: "playControl",
            params: ["isContextMenu": 1, "item_id": "1.2.0"],
            presetParams: [
                "favorites_title": "Mainframe",
                "favorites_type": "audio",
                "favorites_url": "https://bandcamp.com/stream_redirect?enc=mp3-128&track_id=1178320498"
            ]
        )
        let base: [String: JiveItemAction] = [
            "playControl": JiveItemAction(
                cmd: ["Bandcampweekly", "items"],
                params: ["_index": 0, "_quantity": 200, "isContextMenu": 1, "item_id": "1.2", "menu": "Bandcampweekly"],
                itemsParams: "playControlParams",
                nextWindow: nil
            ),
            "play": JiveItemAction(
                cmd: ["Bandcampweekly", "playlist", "play"],
                params: ["menu": "Bandcampweekly"],
                itemsParams: "params",
                nextWindow: "nowPlaying"
            ),
        ]
        if case .terminal(let action) = JiveDispatcher.decide(item: item, base: base) {
            // Must have picked base.play, not the playControl browse cmd.
            #expect(action.cmd == ["Bandcampweekly", "playlist", "play"])
            #expect(action.nextWindow == "nowplaying")
        } else {
            Issue.record("Bandcamp Weekly track must classify .terminal via base.play (round-2 hardware bug)")
        }
    }

    @Test func itemWithNoUsableAction_classifiesUnresolved() {
        // Defensive: an item with no goAction and no resolvable base.go.
        let item = makeItem()
        let base: [String: JiveItemAction] = [:]
        if case .unresolved = JiveDispatcher.decide(item: item, base: base) {
            // pass
        } else {
            Issue.record("Expected .unresolved when no action resolves")
        }
    }

    // MARK: - Bandcamp wire-data fixture replay (3 levels + leaf)

    @Test func bandcampLevel1_articleItem_drills() {
        // Wire-verified level 1: "How Visible Cloaks Stitched Themselves Back
        // Together" item. addAction:"go", no goAction, item-level actions.go
        // → cmd:["Bandcampdaily","items"] with item_id:"0". Tap="go" →
        // resolves item-level go → browse cmd → drill.
        let result = parseFixture(bandcampLevel1Json)
        let (base, items) = JiveItem.parseObj(result)
        #expect(items.count >= 1)
        guard let item = items.first else {
            Issue.record("Fixture missing items")
            return
        }
        if case .drill(let cmd) = JiveDispatcher.decide(item: item, base: base) {
            #expect(cmd.cmd.contains("items"))
        } else {
            Issue.record("Bandcamp level-1 article should drill into items")
        }
    }

    @Test func bandcampLeafTrack_playsViaPlayCmdAndNowPlayingHint() {
        // Wire-verified leaf: goAction:"play", style:"itemplay",
        // params.touchToPlay, base.play with cmd:["Bandcampdaily","playlist",
        // "play"] + nextWindow:"nowPlaying". Three independent terminal
        // signals fire — this is the canonical Bandcamp leaf case that the
        // gi0 fix must continue to handle correctly (no regression).
        let result = parseFixture(bandcampLeafTrackJson)
        let (base, items) = JiveItem.parseObj(result)
        #expect(items.count >= 1)
        guard let item = items.first else {
            Issue.record("Fixture missing items")
            return
        }
        #expect(item.goAction == "play")
        #expect(item.style == "itemplay")
        if case .terminal(let action) = JiveDispatcher.decide(item: item, base: base) {
            // base.play.cmd is ["Bandcampdaily","playlist","play"]
            #expect(action.cmd.contains("play"))
            // nextWindow should be lowercased
            #expect(action.nextWindow == "nowplaying")
        } else {
            Issue.record("Bandcamp leaf track must classify as .terminal")
        }
    }

    // MARK: - Fixtures

    private func parseFixture(_ json: String) -> [String: Any] {
        let data = json.data(using: .utf8)!
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func makeItem(
        goAction: String? = nil,
        type: String? = nil,
        style: String? = nil,
        params: [String: Any] = [:],
        presetParams: [String: Any]? = nil
    ) -> JiveItem {
        JiveItem(
            id: "test",
            text: "Test Item",
            subtitle: nil,
            icon: nil,
            actions: [:],
            params: params,
            goAction: goAction,
            addAction: nil,
            nextWindow: nil,
            type: type,
            style: style,
            presetParams: presetParams
        )
    }

    /// Minimal Bandcamp level-1 article slice (one item + base).
    private let bandcampLevel1Json = """
    {
      "item_loop": [{
        "addAction": "go",
        "text": "How Visible Cloaks Stitched Themselves Back Together",
        "actions": {
          "go": {
            "cmd": ["Bandcampdaily", "items"],
            "params": {"item_id": "0", "menu": "Bandcampdaily"}
          }
        }
      }],
      "base": {
        "actions": {
          "go": {
            "cmd": ["Bandcampdaily", "items"],
            "params": {"menu": "Bandcampdaily"},
            "itemsParams": "params"
          }
        }
      }
    }
    """

    /// Minimal Bandcamp leaf-track slice (one playable item + base.play).
    private let bandcampLeafTrackJson = """
    {
      "item_loop": [{
        "text": "Title Screen\\nVisible Cloaks",
        "goAction": "play",
        "style": "itemplay",
        "params": {
          "touchToPlay": "0.0.1",
          "isContextMenu": 1,
          "item_id": "0.0.1"
        }
      }],
      "base": {
        "actions": {
          "go": {
            "cmd": ["Bandcampdaily", "playlist", "play"],
            "params": {"menu": "Bandcampdaily"},
            "itemsParams": "params",
            "nextWindow": "nowPlaying"
          },
          "play": {
            "cmd": ["Bandcampdaily", "playlist", "play"],
            "params": {"menu": "Bandcampdaily"},
            "itemsParams": "params",
            "nextWindow": "nowPlaying"
          }
        }
      }
    }
    """
}
