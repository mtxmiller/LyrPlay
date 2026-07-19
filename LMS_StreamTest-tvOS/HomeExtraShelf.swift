import SwiftUI
import os.log

/// Horizontal-scroll row of `MediaTile` for one `HomeExtraSection`.
///
/// Renders the section's title as a header, then a horizontal `LazyHStack`
/// of tile-buttons. Tap dispatch fans out by section kind: albums load via
/// `playlistcontrol cmd:load`, artists drill into `ArtistDetailView`,
/// favorites/radios play via `favorites playlist play`, playlists load via
/// `playlistcontrol cmd:load playlist_id`, and plugin (`.jive`) items
/// either drill into `JiveBrowseView` or play (see `JiveItem.dispatch`).
///
/// Plugin sections also show the contributing plugin's server-provided icon
/// as a badge next to the section title — so a "Popular Artists" shelf from
/// Spotty is visually distinct from one from TIDAL (mherger round 2).
///
/// Lives inside `HomeExtraShelvesView`'s outer `LazyVStack` — the vertical
/// scroll is the parent's responsibility. Artist drill-in and plugin
/// drill-in are hoisted to the parent via `onArtistTap` / `onJiveTap` so
/// the `.fullScreenCover` state lives on the screen-root view.
struct HomeExtraShelf: View {
    let section: HomeExtraSection
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager
    let onArtistTap: (Artist) -> Void
    /// Open the plugin-browse `.fullScreenCover` at this destination. Used by
    /// plugin tiles (`.jive` drill), built-in album tiles (`.albumTracks`),
    /// and built-in playlist tiles (`.playlistTracks`) so all three drill
    /// paths share one stack (`HomeExtraShelvesView.jivePath`).
    let onBrowseTap: (BrowseDestination) -> Void

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
            header

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.tileSpacing) {
                    tiles
                }
                .padding(.horizontal, Self.horizontalMargin)
                .padding(.vertical, Self.scrollVerticalPadding)
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 16) {
            headerIcon
            Text(section.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, Self.horizontalMargin)
    }

    /// Leading icon for the shelf header. Plugin shelves use the plugin's
    /// server-provided artwork; built-in shelves use the same SF Symbol the
    /// Settings shelf picker shows (`LibraryShelf.iconSystemName`) — a
    /// built-in section's `id` is its `LibraryShelf` rawValue.
    @ViewBuilder
    private var headerIcon: some View {
        if let pluginIcon = section.pluginIcon {
            CachedAsyncImage(url: settings.absoluteServerURL(pluginIcon)) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let shelf = LibraryShelf(rawValue: section.id) {
            // resizable + scaledToFit so wide symbols (radiowaves, the
            // circular-arrows) are contained — a plain .font() symbol
            // overflows its frame and crowds the title. Inner 26pt glyph
            // in a 36pt slot keeps the title's start x aligned with the
            // plugin-shelf rows above/below.
            Image(systemName: shelf.iconSystemName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .frame(width: 36, height: 36)
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
                    // ejc fix (E1 revised): Select on a built-in album drills
                    // into its track list. "Play all" moves to press-and-hold.
                    action: { onBrowseTap(.albumTracks(albumID: album.id, title: album.name)) }
                )
                .contextMenu { builtinAlbumContextMenu(for: album) }
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
            // Leaves tap-to-play; folder favorites drill into the browse
            // cover via FavoritesFolderView (5bs). Radios are pre-filtered
            // to leaves at parse time, so isFolder is never true there.
            ForEach(Array(favs.enumerated()), id: \.offset) { _, fav in
                MediaTile(
                    title: fav.name,
                    // "audio" is wire taxonomy, not an artist — hide it
                    // (favorites carry no artist field; see FavoritesFolderView).
                    secondary: fav.type == "audio" ? nil : fav.type,
                    artworkURL: LMSArtworkURL.favoriteIcon(fav.icon, settings: settings),
                    placeholderSymbol: fav.isFolder ? "folder.fill"
                        : (section.id == "radios" ? "antenna.radiowaves.left.and.right" : "star.fill"),
                    action: {
                        if fav.isFolder {
                            onBrowseTap(.favoritesFolder(itemID: fav.id, title: fav.name))
                        } else {
                            playFavorite(fav)
                        }
                    }
                )
            }

        case .playlists(let playlists):
            ForEach(playlists, id: \.id) { playlist in
                MediaTile(
                    title: playlist.name,
                    secondary: playlist.trackCountDisplay.isEmpty ? nil : playlist.trackCountDisplay,
                    artworkURL: LMSArtworkURL.materialPlaylist(name: playlist.name, settings: settings),
                    placeholderSymbol: "music.note.list",
                    // ejc fix (E1 revised): Select on a built-in playlist
                    // drills into its track list.
                    action: { onBrowseTap(.playlistTracks(playlistID: playlistDrillID(playlist), title: playlist.name)) }
                )
                .contextMenu { builtinPlaylistContextMenu(for: playlist) }
            }

        case .jive(let base, let items):
            ForEach(items) { item in
                MediaTile(
                    title: item.text,
                    secondary: item.subtitle,
                    artworkURL: item.iconURL(settings: settings),
                    placeholderSymbol: "puzzlepiece.extension.fill",
                    action: { tapJive(item, base: base) }
                )
                .contextMenu { jiveContextMenu(for: item, base: base) }
            }
        }
    }

    /// Numeric playlist_id when LMS gave one; falls back to id otherwise.
    /// `BuiltinTrackListView` and `playlistcontrol` both need the numeric form
    /// for database playlists; `PlaylistsView.playPlaylist` does the same
    /// resolution (`PlaylistsView.swift:112`).
    private func playlistDrillID(_ playlist: Playlist) -> String {
        playlist.originalNumericId.map(String.init) ?? playlist.id
    }

    private var dispatcher: JiveDispatcher {
        JiveDispatcher(coordinator: coordinator, playerID: settings.playerMACAddress)
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

    /// Plugin (`.jive`) tile tap. Asks `JiveDispatcher.decide` to classify
    /// the row, then either fires (terminal — typically a "play this single
    /// item" tile) or opens the browse cover at the drill destination. A
    /// shelf tile has no nav stack of its own, so a play-class fire stays on
    /// Home (no cover to dismiss).
    private func tapJive(_ item: JiveItem, base: [String: JiveItemAction]) {
        switch JiveDispatcher.decide(item: item, base: base) {
        case .terminal(let action):
            os_log(.info, log: logger, "▶️ Play plugin item '%{public}s'", item.text)
            dispatcher.fire(action, label: item.text)
            // No cover to dismiss; the user stays on Home. Server-side play
            // proceeds; if the user wants Now Playing they tap that tab.
        case .drill(let cmd):
            os_log(.info, log: logger, "📂 Drill plugin shelf '%{public}s' → %{public}s",
                   section.title, item.text)
            onBrowseTap(.plugin(cmd))
        case .unresolved:
            os_log(.error, log: logger, "⚠️ Plugin item '%{public}s' has no usable action", item.text)
        }
    }

    /// Press-and-hold menu for a plugin tile — Play / Add. A shelf tile has no
    /// nav stack, so `nextWindow` from these actions is not routed (the play
    /// itself still happens server-side).
    @ViewBuilder
    private func jiveContextMenu(for item: JiveItem, base: [String: JiveItemAction]) -> some View {
        if let play = item.resolvedAction(named: "play", base: base) {
            Button {
                dispatcher.fire(play, label: item.text)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
        }
        if let add = item.resolvedAction(named: item.addActionName, base: base) {
            Button {
                dispatcher.fire(add, label: item.text)
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
        }
    }

    /// Press-and-hold menu for a built-in album tile — Play all / Add all.
    /// Replaces the old tap-to-play affordance (E1 revised: Select now drills).
    @ViewBuilder
    private func builtinAlbumContextMenu(for album: Album) -> some View {
        Button {
            playAlbum(album)
        } label: {
            Label("Play All", systemImage: "play.fill")
        }
        Button {
            addAlbum(album)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }

    /// Press-and-hold menu for a built-in playlist tile — Play all / Add all.
    @ViewBuilder
    private func builtinPlaylistContextMenu(for playlist: Playlist) -> some View {
        Button {
            playPlaylist(playlist)
        } label: {
            Label("Play All", systemImage: "play.fill")
        }
        Button {
            addPlaylist(playlist)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }

    private func addAlbum(_ album: Album) {
        os_log(.info, log: logger, "➕ Add album from shelf '%{public}s': %{public}s",
               section.id, album.name)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:add", "album_id:\(album.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }

    private func addPlaylist(_ playlist: Playlist) {
        let playlistID = playlistDrillID(playlist)
        os_log(.info, log: logger, "➕ Add playlist from shelf '%{public}s': %{public}s",
               section.id, playlist.name)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:add", "playlist_id:\(playlistID)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
