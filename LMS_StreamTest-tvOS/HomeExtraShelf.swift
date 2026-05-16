import SwiftUI
import os.log

/// Horizontal-scroll row of `MediaTile` for one `HomeExtraSection`.
///
/// Renders the section's title as a header, then a horizontal `LazyHStack`
/// of tile-buttons. Tap dispatch fans out by section kind: albums load via
/// `playlistcontrol cmd:load`, artists drill into `ArtistDetailView`,
/// favorites/radios play via `favorites playlist play`, playlists load via
/// `playlistcontrol cmd:load playlist_id`.
///
/// Lives inside `HomeExtraShelvesView`'s outer `LazyVStack` — the vertical
/// scroll is the parent's responsibility. Artist drill-in is hoisted to the
/// parent via `onArtistTap` so the `.fullScreenCover` state lives on the
/// screen-root view (matches SearchView's pattern from 98q.8 D4=A).
struct HomeExtraShelf: View {
    let section: HomeExtraSection
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager
    let onArtistTap: (Artist) -> Void

    /// Spacing between tiles inside the horizontal scroll. 48pt — tuned on
    /// real Apple TV hardware after Elissen's first-look feedback that 32pt
    /// looked cramped; gives the focus-engine halo visible breathing room
    /// between neighbors at 240pt tile width.
    private static let tileSpacing: CGFloat = 48

    /// Left/right margin matching LibraryView's 80pt picker margin — keeps
    /// shelves indented away from the safe-area edge on 4K displays.
    private static let horizontalMargin: CGFloat = 80

    /// Vertical padding inside the horizontal scroll. 40pt — tuned on real
    /// hardware after the focus halo rode up into the shelf header above
    /// (mherger feedback #2 + Elissen's first-look). Gives the lift room
    /// against the header and the next shelf below.
    private static let scrollVerticalPadding: CGFloat = 40

    private let logger = OSLog(subsystem: "com.lmsstream", category: "HomeExtraShelf")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, Self.horizontalMargin)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.tileSpacing) {
                    tiles
                }
                .padding(.horizontal, Self.horizontalMargin)
                .padding(.vertical, Self.scrollVerticalPadding)
            }
        }
    }

    // MARK: - Tiles per section kind

    @ViewBuilder
    private var tiles: some View {
        switch section.items {
        case .albums(let albums):
            ForEach(albums, id: \.id) { album in
                MediaTile(
                    title: album.name,
                    secondary: album.artist.isEmpty ? nil : album.artist,
                    artworkURL: LMSArtworkURL.cover(
                        coverID: album.artworkTrackId,
                        fallbackID: album.id,
                        settings: settings
                    ),
                    placeholderSymbol: "opticaldisc",
                    action: { playAlbum(album) }
                )
            }

        case .artists(let artists):
            ForEach(artists, id: \.id) { artist in
                MediaTile(
                    title: artist.name,
                    secondary: nil,
                    artworkURL: LMSArtworkURL.maiArtist(id: artist.id, settings: settings),
                    placeholderSymbol: "person.fill",
                    action: { onArtistTap(artist) }
                )
            }

        case .favorites(let favs):
            // Favorites and radios both arrive in this case — identical wire
            // shape, dispatch forks inside `playFavorite` on section.id.
            // Identity by offset because favorite ids can repeat in flattened
            // folder cases (matches FavoritesView's identity strategy).
            ForEach(Array(favs.enumerated()), id: \.offset) { _, fav in
                MediaTile(
                    title: fav.name,
                    secondary: fav.type,
                    artworkURL: LMSArtworkURL.favoriteIcon(fav.icon, settings: settings),
                    placeholderSymbol: section.id == "radios" ? "antenna.radiowaves.left.and.right" : "star.fill",
                    action: { playFavorite(fav) }
                )
            }

        case .playlists(let playlists):
            ForEach(playlists, id: \.id) { playlist in
                MediaTile(
                    title: playlist.name,
                    secondary: playlist.trackCountDisplay.isEmpty ? nil : playlist.trackCountDisplay,
                    artworkURL: LMSArtworkURL.materialPlaylist(name: playlist.name, settings: settings),
                    placeholderSymbol: "music.note.list",
                    action: { playPlaylist(playlist) }
                )
            }
        }
    }

    // MARK: - Tap dispatch

    private func playAlbum(_ album: Album) {
        os_log(.info, log: logger, "▶️ Play album from shelf '%{public}s': %{public}s (id=%{public}s)",
               section.id, album.name, album.id)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:load", "album_id:\(album.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }

    private func playFavorite(_ fav: FavoriteItem) {
        os_log(.info, log: logger, "▶️ Play favorite/radio from shelf '%{public}s': %{public}s",
               section.id, fav.name)
        // Radios shelf items have a synthesized URL-as-id (live server's
        // `material-skin-query radios` returns no top-level id field, so
        // HomeExtraResponse.parse uses url as id). Dispatch via `playlist
        // play <url>` instead of `favorites playlist play item_id:N` which
        // expects an item_id tree position.
        let cliArgs: [String]
        if section.id == "radios" {
            cliArgs = ["playlist", "play", fav.id]   // fav.id IS the URL
        } else {
            cliArgs = ["favorites", "playlist", "play", "item_id:\(fav.id)"]
        }
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, cliArgs]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }

    private func playPlaylist(_ playlist: Playlist) {
        os_log(.info, log: logger, "▶️ Play playlist from shelf '%{public}s': %{public}s (id=%{public}s)",
               section.id, playlist.name, playlist.id)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:load", "playlist_id:\(playlist.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
