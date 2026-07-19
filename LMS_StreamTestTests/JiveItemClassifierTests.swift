import XCTest
@testable import LMS_StreamTest

/// Tests for the build-12 classifier predicates added to `PlaylistModels.swift`:
/// `ResolvedJiveAction.isPlayVerb` and `JiveItem.hasLeafHint`. Plus the
/// false-positive guard verifying that `cmd`-says-browse always beats
/// `type`-says-leaf.
///
/// Round-4 gi0 + E2: the locked classifier is cmd-first with leaf hints as
/// corroborating evidence. These tests guard the predicate against drift if a
/// future plugin form forces an extension.
final class JiveItemClassifierTests: XCTestCase {

    // MARK: - ResolvedJiveAction.isPlayVerb — SlimBrowse cmd-array form

    func testIsPlayVerb_BandcampLeafPlayCmd_returnsTrue() {
        // Wire-verified Bandcamp leaf: cmd:["Bandcampdaily","playlist","play"]
        let action = ResolvedJiveAction(
            cmd: ["Bandcampdaily", "playlist", "play"],
            params: [:],
            nextWindow: "nowplaying"
        )
        XCTAssertTrue(action.isPlayVerb)
    }

    func testIsPlayVerb_RadioUrlSuffixPlayCmd_returnsTrue() {
        // ["playlist","play","<url>"] — verb at position [-2], not [-1].
        // Suffix-match would miss this; the locked predicate is token-anywhere.
        let action = ResolvedJiveAction(
            cmd: ["playlist", "play", "http://example.com/stream.mp3"],
            params: [:],
            nextWindow: nil
        )
        XCTAssertTrue(action.isPlayVerb)
    }

    func testIsPlayVerb_PluginAddCmd_returnsTrue() {
        // A plugin's add action: ["spotty","playlist","add"]
        let action = ResolvedJiveAction(
            cmd: ["spotty", "playlist", "add"],
            params: [:],
            nextWindow: nil
        )
        XCTAssertTrue(action.isPlayVerb)
    }

    func testIsPlayVerb_PluginInsertCmd_returnsTrue() {
        let action = ResolvedJiveAction(
            cmd: ["plugin", "playlist", "insert"],
            params: [:],
            nextWindow: nil
        )
        XCTAssertTrue(action.isPlayVerb)
    }

    // MARK: - isPlayVerb — SlimBrowse browse verbs (must be drill)

    func testIsPlayVerb_BrowseItemsCmd_returnsFalse() {
        // Bandcamp folder drill: ["Bandcampdaily","items"]
        let action = ResolvedJiveAction(
            cmd: ["Bandcampdaily", "items"],
            params: [:],
            nextWindow: nil
        )
        XCTAssertFalse(action.isPlayVerb)
    }

    func testIsPlayVerb_BrowseTracksCmd_returnsFalse() {
        let action = ResolvedJiveAction(
            cmd: ["tracks"],
            params: [:],
            nextWindow: nil
        )
        XCTAssertFalse(action.isPlayVerb)
    }

    func testIsPlayVerb_BrowseAlbumsCmd_returnsFalse() {
        let action = ResolvedJiveAction(
            cmd: ["albums", "0", "50", "sort:new"],
            params: [:],
            nextWindow: nil
        )
        XCTAssertFalse(action.isPlayVerb)
    }

    func testIsPlayVerb_BrowseVerbWinsOverPlayToken() {
        // Defensive: a cmd containing BOTH a browse verb AND a play token
        // (hypothetical ["albums","play"]) must classify as browse, not play.
        // This is the false-positive guard at the cmd level.
        let action = ResolvedJiveAction(
            cmd: ["albums", "play"],
            params: [:],
            nextWindow: nil
        )
        XCTAssertFalse(action.isPlayVerb,
            "browse verb must beat play token (false-positive guard)")
    }

    // MARK: - isPlayVerb — playlistcontrol param form

    func testIsPlayVerb_PlaylistcontrolCmdLoad_returnsTrue() {
        // Built-in album play: cmd:["playlistcontrol"], cliArgs:["playlistcontrol","cmd:load","album_id:42"]
        let action = ResolvedJiveAction(
            cmd: ["playlistcontrol"],
            params: ["cmd": "load", "album_id": "42"],
            nextWindow: nil
        )
        XCTAssertTrue(action.isPlayVerb)
    }

    func testIsPlayVerb_PlaylistcontrolCmdAdd_returnsTrue() {
        let action = ResolvedJiveAction(
            cmd: ["playlistcontrol"],
            params: ["cmd": "add", "album_id": "42"],
            nextWindow: nil
        )
        XCTAssertTrue(action.isPlayVerb)
    }

    func testIsPlayVerb_PlaylistcontrolCmdInsert_returnsTrue() {
        let action = ResolvedJiveAction(
            cmd: ["playlistcontrol"],
            params: ["cmd": "insert", "track_id": "99"],
            nextWindow: nil
        )
        XCTAssertTrue(action.isPlayVerb)
    }

    func testIsPlayVerb_PlaylistcontrolWithoutCmdParam_returnsFalse() {
        // Defensive: a `playlistcontrol` cmd with no recognized `cmd:` param
        // is not a play. (No real wire form is known to produce this; the
        // predicate must not classify it as play just because the verb is
        // `playlistcontrol`.)
        let action = ResolvedJiveAction(
            cmd: ["playlistcontrol"],
            params: ["something": "else"],
            nextWindow: nil
        )
        XCTAssertFalse(action.isPlayVerb)
    }

    // MARK: - isPlayVerb — defensive

    func testIsPlayVerb_EmptyCmd_returnsFalse() {
        let action = ResolvedJiveAction(cmd: [], params: [:], nextWindow: nil)
        XCTAssertFalse(action.isPlayVerb)
    }

    // MARK: - JiveItem.hasLeafHint

    func testHasLeafHint_StyleItemplay_returnsTrue() {
        let item = makeItem(style: "itemplay")
        XCTAssertTrue(item.hasLeafHint)
    }

    func testHasLeafHint_TouchToPlayParam_returnsTrue() {
        let item = makeItem(params: ["touchToPlay": "0.0.1"])
        XCTAssertTrue(item.hasLeafHint)
    }

    func testHasLeafHint_TypeAudio_returnsTrue() {
        let item = makeItem(type: "audio")
        XCTAssertTrue(item.hasLeafHint)
    }

    func testHasLeafHint_TypeTrack_returnsTrue() {
        let item = makeItem(type: "track")
        XCTAssertTrue(item.hasLeafHint)
    }

    func testHasLeafHint_TypePlaylist_returnsFalse() {
        // type:"playlist" is a container, not a leaf.
        let item = makeItem(type: "playlist")
        XCTAssertFalse(item.hasLeafHint)
    }

    func testHasLeafHint_NoHints_returnsFalse() {
        let item = makeItem()
        XCTAssertFalse(item.hasLeafHint)
    }

    func testHasLeafHint_PresetParamsFavoritesUrl_returnsTrue() {
        // Bandcamp Weekly leaf pattern: item carries presetParams with a
        // favorites_url. No style:itemplay, no touchToPlay, no type=audio —
        // presetParams is the only leaf signal the server provides.
        let item = makeItem(presetParams: [
            "favorites_title": "Mainframe",
            "favorites_type": "audio",
            "favorites_url": "https://bandcamp.com/stream_redirect?enc=mp3-128&track_id=1178320498"
        ])
        XCTAssertTrue(item.hasLeafHint)
    }

    func testHasLeafHint_PresetParamsEmpty_returnsFalse() {
        // Defensive: an empty presetParams should NOT classify as leaf.
        let item = makeItem(presetParams: [:])
        XCTAssertFalse(item.hasLeafHint)
    }

    // MARK: - Helper

    /// Minimal `JiveItem` builder for hasLeafHint tests. The required fields
    /// (id, text) are stubbed; the optional fields under test are passed in.
    private func makeItem(
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
            goAction: nil,
            addAction: nil,
            nextWindow: nil,
            type: type,
            style: style,
            presetParams: presetParams
        )
    }
}
