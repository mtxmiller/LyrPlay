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
        case byArtist(id: String)  // 98q.8: ArtistDetailView drill-in target

        /// LMS query param. RecentlyPlayed/New use a `sort:` filter; byArtist uses
        /// the `artist_id:N` filter (default sort = album title).
        var paramValue: String {
            switch self {
            case .recentlyPlayed: return "sort:recentlyplayed"
            case .new: return "sort:new"
            case .byArtist(let id): return "artist_id:\(id)"
            }
        }

        var emptyIcon: String {
            switch self {
            case .recentlyPlayed: return "clock"
            case .new: return "sparkles"
            case .byArtist: return "music.note"
            }
        }

        var emptyTitle: String {
            switch self {
            case .recentlyPlayed: return "Nothing played recently"
            case .new: return "No new music"
            case .byArtist: return "No albums found"
            }
        }

        var emptySubtitle: String {
            switch self {
            case .recentlyPlayed: return "Albums you play will appear here."
            case .new: return "Add music to your LMS library to see it here."
            case .byArtist: return "This artist has no albums in the LMS library."
            }
        }
    }

    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager
    let sort: Sort

    @State private var albums: [Album] = []
    @State private var isLoading: Bool = false
    @State private var hasFetched: Bool = false

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
        List {
            ForEach(albums, id: \.id) { album in
                Button {
                    playAlbum(album)
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
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
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

    // MARK: - Tap-to-play

    private func playAlbum(_ album: Album) {
        os_log(.info, log: logger, "▶️ Play album: %{public}s (id=%{public}s)", album.name, album.id)
        // Player-targeted. `playlistcontrol cmd:load album_id:N` per CarPlay
        // CarPlaySceneDelegate.swift:2434. Replaces queue + starts at track 1. User stays on
        // Library per D6.
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:load", "album_id:\(album.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
