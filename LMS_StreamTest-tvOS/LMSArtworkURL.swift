import Foundation

/// Builds artwork URLs against the user's active LMS server.
///
/// Centralizes the URL composition that QueueView, FavoritesView, AlbumListView, and
/// PlaylistsView all need. Single fix-site for the credential-leak follow-up
/// (`LMS_StreamTest-7e4`) and the AsyncImage shared-cache work (`LMS_StreamTest-ppz`).
enum LMSArtworkURL {

    /// LMS `/music/<id>/cover_200x200_o.jpg` — the canonical track/album cover endpoint.
    /// Pass the coverid first; falls back to a content id (e.g. track.id, album id) if coverid is missing.
    /// Returns nil only when both ids are absent or empty.
    static func cover(coverID: String?, fallbackID: String?, settings: SettingsManager) -> URL? {
        let id: String
        if let c = coverID, !c.isEmpty {
            id = c
        } else if let f = fallbackID, !f.isEmpty {
            id = f
        } else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = settings.activeServerHost
        components.port = settings.activeServerWebPort
        components.path = "/music/\(id)/cover_200x200_o.jpg"

        // Inline credentials when the server requires auth. Tracked for credential
        // leak via cache keys + http wire as LMS_StreamTest-7e4.
        let user = settings.activeServerUsername
        if !user.isEmpty {
            components.user = user
            components.password = settings.activeServerPassword
        }
        return components.url
    }

    /// Resolves a favorite item's `icon`/`image`/`cover` string into a URL.
    ///
    /// Favorites can carry artwork in three shapes:
    ///   1. Absolute URL (`http://...` / `https://...`) — returned as-is, auth injected if same-host.
    ///   2. Server-relative path (`/imageproxy/...`, `/html/images/radio.png`) — resolved against
    ///      the active LMS host.
    ///   3. nil/empty — returns nil; caller falls back to the placeholder artwork view.
    static func favoriteIcon(_ iconString: String?, settings: SettingsManager) -> URL? {
        guard let raw = iconString, !raw.isEmpty else { return nil }

        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = settings.activeServerHost
        components.port = settings.activeServerWebPort
        components.path = raw.hasPrefix("/") ? raw : "/" + raw

        let user = settings.activeServerUsername
        if !user.isEmpty {
            components.user = user
            components.password = settings.activeServerPassword
        }
        return components.url
    }
}
