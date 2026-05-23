import SwiftUI
import os.log

/// Library tab → Recently Played + New Music sub-views. One implementation, two configs.
///
/// Recently Played: `["albums", 0, 50, "sort:recentlyplayed", "tags:ajly"]` (vanilla LMS;
/// see Queries.pm:302 valid sorts; matches lms-material home-menu Recently Played entry).
/// New Music: `["albums", 0, 50, "sort:new", "tags:ajly"]` (matches CarPlay's
/// fetchNewMusicWithArtwork at CarPlaySceneDelegate.swift:2027).
///
/// Both lists refresh on `.onAppear` only — re-entering the Library tab refetches.
/// We do NOT live-refresh on track change because (a) the user is typically on Now Playing
/// during play, not on RP, and (b) per-track refetch was wasteful (50 rows + AsyncImage
/// cascade per song). Stale-while-on-tab is acceptable; tab re-entry shows fresh state.
///
/// Tap loads + plays the whole album via `playlistcontrol cmd:load album_id:N` (CarPlay
/// pattern at line 2434). User stays on Library per D6.
struct AlbumListView: View {

    enum Sort: Equatable {
        case recentlyPlayed
        case new
        case alphabetical                 // BrowseLibraryView fallback "Albums"
        case byArtist(id: String)         // 98q.8: ArtistDetailView drill-in target
        case byGenre(id: String, name: String)  // BrowseLibraryView fallback "Genres" drill-in

        /// LMS query param. RecentlyPlayed/New/Alphabetical use a `sort:` filter;
        /// byArtist/byGenre use the entity-id filter (default sort = album title).
        var paramValue: String {
            switch self {
            case .recentlyPlayed: return "sort:recentlyplayed"
            case .new: return "sort:new"
            case .alphabetical: return "sort:album"
            case .byArtist(let id): return "artist_id:\(id)"
            case .byGenre(let id, _): return "genre_id:\(id)"
            }
        }

        var emptyIcon: String {
            switch self {
            case .recentlyPlayed: return "clock"
            case .new: return "sparkles"
            case .alphabetical: return "music.note.list"
            case .byArtist: return "music.note"
            case .byGenre: return "music.note"
            }
        }

        var emptyTitle: String {
            switch self {
            case .recentlyPlayed: return "Nothing played recently"
            case .new: return "No new music"
            case .alphabetical: return "No albums"
            case .byArtist: return "No albums found"
            case .byGenre: return "No albums in this genre"
            }
        }

        var emptySubtitle: String {
            switch self {
            case .recentlyPlayed: return "Albums you play will appear here."
            case .new: return "Add music to your LMS library to see it here."
            case .alphabetical: return "Add music to your LMS library to see it here."
            case .byArtist: return "This artist has no albums in the LMS library."
            case .byGenre: return "No albums tagged with this genre."
            }
        }
    }

    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager
    let sort: Sort

    @State private var albums: [Album] = []
    @State private var isLoading: Bool = false
    @State private var hasFetched: Bool = false
    /// Drives the drill-into-tracks push on the host's `NavigationStack`
    /// (E1 revised: Select drills, not plays). The host doesn't need to
    /// declare anything — this view owns its own `.navigationDestination(item:)`.
    /// Stored as `BuiltinTrackListView.Source` (Hashable) — Album itself is
    /// not Hashable (carries a UIImage), and the .playlist case is unused here.
    @State private var selectedDrill: BuiltinTrackListView.Source? = nil

    private let logger = OSLog(subsystem: "com.lmsstream", category: "AlbumListView")

    var body: some View {
        Group {
            if isLoading && !hasFetched {
                ProgressView()
                    .scaleEffect(2.0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty && hasFetched {
                emptyState
            } else {
                listView
            }
        }
        .onAppear { if !hasFetched { fetch() } }
        .navigationDestination(item: $selectedDrill) { source in
            BuiltinTrackListView(
                source: source,
                coordinator: coordinator,
                settings: settings
            )
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: sort.emptyIcon)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(sort.emptyTitle)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(sort.emptySubtitle)
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var listView: some View {
        // Identity by album.id: stable across re-fetches so SwiftUI diffs rows correctly
        // when the server reorders RP. Avoids row remount + AsyncImage refetch on every refresh.
        TVList {
            ForEach(albums, id: \.id) { album in
                Button {
                    // E1 revised: Select drills into the album's tracks so the
                    // user can start from a song. "Play all" lives in the
                    // press-and-hold context menu below.
                    selectedDrill = .album(id: album.id, title: album.name)
                } label: {
                    MediaRow(
                        primary: album.name,
                        secondary: rowSecondary(for: album),
                        artworkURL: LMSArtworkURL.cover(
                            coverID: album.artworkTrackId,
                            fallbackID: album.id,
                            settings: settings
                        )
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { albumContextMenu(for: album) }
                .tvListRow()
            }
        }
    }

    /// Press-and-hold menu — Play all / Add all. The default tap drills (above);
    /// these stay as the explicit whole-album affordances.
    @ViewBuilder
    private func albumContextMenu(for album: Album) -> some View {
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

    private func rowSecondary(for album: Album) -> String? {
        // "Artist • Year" if both present, else either, else nil (MediaRow hides empty secondary).
        let artist = album.artist.isEmpty ? nil : album.artist
        let year = album.year.map(String.init)
        switch (artist, year) {
        case let (a?, y?): return "\(a) • \(y)"
        case let (a?, nil): return a
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    // MARK: - Fetch

    private func fetch() {
        isLoading = true
        // System-scoped query. Cap at 50 — per learning ppz-deferred, AsyncImage has no shared
        // cache so long lists re-download artwork on tab toggle. 50 keeps render snappy.
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["albums", 0, 50, sort.paramValue, "tags:ajly"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { response in
            DispatchQueue.main.async {
                isLoading = false
                hasFetched = true
                guard let result = response["result"] as? [String: Any] else {
                    os_log(.error, log: logger, "❌ Albums fetch (%{public}s): invalid response", sort.paramValue)
                    return
                }
                if let loop = result["albums_loop"] as? [[String: Any]] {
                    albums = Album.parseLoop(loop)
                } else {
                    albums = []
                }
                os_log(.info, log: logger, "✅ Albums (%{public}s): %d items", sort.paramValue, albums.count)
            }
        }
    }

    // MARK: - Whole-album actions (press-and-hold menu only)

    private func playAlbum(_ album: Album) {
        os_log(.info, log: logger, "▶️ Play album (Play All): %{public}s (id=%{public}s)", album.name, album.id)
        // Replaces queue + starts at track 1. User stays on Library per D6.
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:load", "album_id:\(album.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }

    private func addAlbum(_ album: Album) {
        os_log(.info, log: logger, "➕ Add album: %{public}s (id=%{public}s)", album.name, album.id)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:add", "album_id:\(album.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
