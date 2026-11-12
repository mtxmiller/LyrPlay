import Foundation

/// After a reconnect, Material switches to its default player when that player
/// "re-appears" in the refreshed player list (lms-material store.js, Material
/// #387) — even while LyrPlay keeps playing (forum report, bd vdb6). Decide
/// from the bridge's player-switch report whether to put LyrPlay back.
enum MaterialPlayerRestore {
    /// How long after the connection came back a switch away from us counts as
    /// Material's own doing rather than the user's.
    static let window: TimeInterval = 10

    /// - previousID: the player Material reported before this switch (nil after a reload)
    /// - newID: the player it just switched to
    /// - localID: our player id
    /// - reconnectedAgo: seconds since the SlimProto connection was (re)established
    /// - playing: LyrPlay is playing audio now
    static func shouldRestore(previousID: String?, newID: String?, localID: String,
                              reconnectedAgo: TimeInterval?, playing: Bool) -> Bool {
        guard !localID.isEmpty, let newID = newID, !isOurs(newID, localID) else { return false }
        guard let ago = reconnectedAgo, ago >= 0, ago <= window else { return false }
        if let previous = previousID { return isOurs(previous, localID) }
        // The page reloaded (no earlier report): keep LyrPlay in front only
        // while it is the one playing.
        return playing
    }

    /// Runs in the Material page from load. Notes which Vuex mutation last
    /// changed the selected player: `setPlayers` is the player-list refresh
    /// (Material's own switch to its default player), `setPlayer` is a choice
    /// made in the UI. Waits for Material's store, which is created after load.
    static let watchScript = """
    (function install() {
        if (window.__lyrPlayerWatch) { return; }
        var s = (typeof bus !== 'undefined' && bus && bus.$store) ||
                (typeof app !== 'undefined' && app && app.$store) || null;
        if (!s || typeof s.subscribe !== 'function') { setTimeout(install, 500); return; }
        window.__lyrPlayerWatch = true;
        var last = s.state.player ? s.state.player.id : null;
        s.subscribe(function (mutation, state) {
            var now = state.player ? state.player.id : null;
            if (now !== last) { last = now; window.__lyrPlayerSwitchBy = mutation.type; }
        });
    })();
    """

    /// Selects our player again, unless the last switch was the user's own
    /// choice: within the window after a reconnect a tap on another player
    /// looked the same as Material's switch and was undone (several taps were
    /// needed until the window ran out). Returns a word for the log: `user`
    /// (left alone), `restored`, `no-material`.
    static func restoreScript(localID: String) -> String {
        let id = localID.filter { $0.isHexDigit || $0 == ":" }
        return """
        (function (id) {
            if (window.__lyrPlayerSwitchBy === 'setPlayer') { return 'user'; }
            if (typeof setCurrentPlayer !== 'function') { return 'no-material'; }
            setCurrentPlayer(id);
            return 'restored';
        })('\(id)');
        """
    }

    private static func isOurs(_ id: String, _ localID: String) -> Bool {
        id.caseInsensitiveCompare(localID) == .orderedSame
    }
}
