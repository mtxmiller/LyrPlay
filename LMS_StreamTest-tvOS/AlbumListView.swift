import SwiftUI
import os.log

/// Library tab → Recently Played + New Music sub-views. One implementation, two configs.
///
/// Recently Played: `["albums", 0, 50, "sort:recentlyplayed", "tags:ajly"]` (vanilla LMS;
/// see Queries.pm:302 valid sorts; matches lms-material home-menu Recently Played entry).
/// New Music: `["albums", 0, 50, "sort:new", "tags:ajly"]` (matches CarPlay's
/// fetchNewMusicWithArtwork at CarPlaySceneDelegate.swift:2027).
///
/// RP refreshes on `nowPlaying.currentTrackTitle` change (a new album playing changes the
/// list server-side). New Music does not — recently-added is independent of playback.
///
/// Tap loads + plays the whole album via `playlistcontrol cmd:load album_id:N` (CarPlay
/// pattern at line 2434). User stays on Library per D6.
struct AlbumListView: View {

    enum Sort {
        case recentlyPlayed
        case new

        var paramValue: String {
            switch self {
            case .recentlyPlayed: return "sort:recentlyplayed"
            case .new: return "sort:new"
            }
        }

        /// Whether this list refreshes when the currently playing track changes.
        /// RP changes on every album-load broadcast; New Music doesn't.
        var refreshesOnPlayback: Bool {
            switch self {
            case .recentlyPlayed: return true
            case .new: return false
            }
        }

        var emptyTitle: String {
            switch self {
            case .recentlyPlayed: return "Nothing played recently"
            case .new: return "No new music"
            }
        }

        var emptySubtitle: String {
            switch self {
            case .recentlyPlayed: return "Albums you play will appear here."
            case .new: return "Add music to your LMS library to see it here."
            }
        }
    }

    let coordinator: SlimProtoCoordinator
    @ObservedObject var nowPlaying: NowPlayingManager
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
        .onChange(of: nowPlaying.currentTrackTitle) { _, _ in
            // Refresh RP when a new track plays — server-side ordering changes. New Music ignores.
            if sort.refreshesOnPlayback && hasFetched {
                fetch()
            }
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: sort == .recentlyPlayed ? "clock" : "sparkles")
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
        // Identity by array offset: same album won't repeat in a single response, but enumerate
        // for forward-compat parity with QueueView.
        List {
            ForEach(Array(albums.enumerated()), id: \.offset) { _, album in
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
