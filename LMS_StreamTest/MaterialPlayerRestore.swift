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

    private static func isOurs(_ id: String, _ localID: String) -> Bool {
        id.caseInsensitiveCompare(localID) == .orderedSame
    }
}
