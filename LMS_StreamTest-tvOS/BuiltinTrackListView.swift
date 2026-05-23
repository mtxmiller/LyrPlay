import SwiftUI
import os.log

/// Drill destination for built-in albums and playlists (round-4 `ejc` fix).
///
/// Renders the tracks of a library album (`["titles", 0, N, "album_id:X",
/// "tags:daltC"]` — CarPlay `:2235` pattern) or a saved playlist
/// (`["playlists", "tracks", 0, N, "playlist_id:X", "tags:dalC"]` — CarPlay
/// `:755` pattern). Select on a track plays from that index using the
/// **atomic** `playlistcontrol cmd:load <kind>_id:X play_index:N` form —
/// CarPlay `:2404` (album) and `:452` (playlist) both use it successfully.
/// One JSON-RPC per Select; no two-command race.
///
/// Reached from three different push mechanisms (the same view, different
/// hosts):
/// - `HomeExtraShelvesView` plugin-browse cover → `BrowseDestination.albumTracks`
///   / `.playlistTracks` element on `jivePath`.
/// - `AlbumListView` row Select → local `NavigationLink(value: album)` push,
///   resolved by AlbumListView's own `.navigationDestination(item:)`.
/// - `PlaylistsView` row Select → same pattern with `playlist`.
///
/// Each track row has a context menu: "Play from here" (the default tap) and
/// "Add to Queue" (this track only). The parent album / playlist tile's own
/// context menu is where "Play all" / "Add all" live — not here. The user
/// already drilled in; the actions at this level are per-track.
struct BuiltinTrackListView: View {

    /// What we're showing tracks for. The two cases use different JSON-RPC
    /// queries (`titles album_id:` vs `playlists tracks playlist_id:`) and
    /// different `playlistcontrol` keys.
    enum Source: Hashable, Identifiable {
        case album(id: String, title: String)
        case playlist(id: String, title: String)

        var title: String {
            switch self {
            case .album(_, let t), .playlist(_, let t): return t
            }
        }

        /// Param key used by `playlistcontrol cmd:load` for this source.
        var idParam: String {
            switch self {
            case .album(let id, _): return "album_id:\(id)"
            case .playlist(let id, _): return "playlist_id:\(id)"
            }
        }

        /// Identifiable conformance — required for `.fullScreenCover(item:)`
        /// presentation in SearchView. Synthesized from kind + id.
        var id: String {
            switch self {
            case .album(let aid, _): return "album:\(aid)"
            case .playlist(let pid, _): return "playlist:\(pid)"
            }
        }
    }

    /// Local minimal track model. We deliberately do NOT round-trip through
    /// `PlaylistTrack.parseLoop` (Codable + JSONSerialization re-encode) — that
    /// path failed at runtime on `titles_loop` responses (all 10 tracks dropped
    /// with `DecodingError.dataCorrupted`, despite the same data decoding fine
    /// in isolation). Manual dict reads are simpler, bypass whatever the
    /// decoder didn't like, and we only need a handful of fields for display
    /// and play-from-here.
    struct Track: Identifiable {
        let id: String
        let title: String
        let artist: String?
        let album: String?
        let coverID: String?
    }

    let source: Source
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var tracks: [Track] = []
    @State private var isLoading: Bool = true
    @State private var loadFailed: Bool = false
    @State private var fetchToken: Int = 0

    private let logger = OSLog(subsystem: "com.lmsstream", category: "BuiltinTrackListView")

    var body: some View {
        TVScreen {
            Group {
                if isLoading {
                    ProgressView()
                        .scaleEffect(2.0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed {
                    errorState
                } else if tracks.isEmpty {
                    emptyState
                } else {
                    listView
                }
            }
        }
        // No navigationTitle — on a tvOS List root it renders as a large
        // title floating over the scrolled content (5cecb18 dropped the
        // same pattern from Settings; the user reported the same
        // overlap-with-track-name issue here in build 12 QA). The user
        // just drilled into this album/playlist and knows where they are.
        .task(id: fetchToken) { await fetch() }
    }

    // MARK: - States

    private var errorState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("Couldn't load")
                .font(.largeTitle)
            Button("Retry") { fetchToken += 1 }
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("No tracks")
                .font(.largeTitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        TVList {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    playFromHere(track: track, index: index)
                } label: {
                    MediaRow(
                        primary: track.title,
                        secondary: rowSecondary(for: track),
                        artworkURL: LMSArtworkURL.cover(
                            coverID: track.coverID,
                            fallbackID: track.id,
                            settings: settings
                        ),
                        placeholderSymbol: "music.note"
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { trackContextMenu(for: track) }
                .tvListRow()
            }
        }
    }

    @ViewBuilder
    private func trackContextMenu(for track: Track) -> some View {
        Button {
            addToQueue(track: track)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }
    }

    /// "Artist • Album" if both present and the album name differs from the
    /// source title (avoid "Track 1 — Artist • Album Name" when the user is
    /// already on the Album Name screen). Falls back gracefully.
    private func rowSecondary(for track: Track) -> String? {
        let artist = track.artist
        let album = track.album
        let sourceTitle = source.title
        switch (artist, album) {
        case let (a?, b?) where b != sourceTitle: return "\(a) • \(b)"
        case let (a?, _): return a
        case let (nil, b?) where b != sourceTitle: return b
        default: return nil
        }
    }

    // MARK: - Fetch

    @MainActor
    private func fetch() async {
        isLoading = true
        loadFailed = false
        let request: [String: Any]
        switch source {
        case .album(let id, _):
            // `titles album_id:X tags:daltCj sort:tracknum` — CarPlay :2235
            // shape plus the explicit sort. Tags d=duration, a=artist,
            // l=album, t=trackNumber, C=compilation, j=coverart.
            //
            // `sort:tracknum` is critical: our row index drives the
            // `play_index:` we send on tap (play-from-here), and the server's
            // `playlistcontrol cmd:load album_id:X play_index:N` loads the
            // album in canonical tracknum order. If our display order
            // differed from the load order (e.g. server returning alphabetical
            // by default on some albums), the wrong track played — verified
            // on hardware 2026-05-23 with "Ultrasonic Studios 1972".
            request = [
                "id": 1,
                "method": "slim.request",
                "params": ["", ["titles", 0, 500, "album_id:\(id)", "tags:daltCj", "sort:tracknum"]]
            ]
        case .playlist(let id, _):
            // `playlists tracks playlist_id:X tags:dalCj` — CarPlay :755.
            request = [
                "id": 1,
                "method": "slim.request",
                "params": ["", ["playlists", "tracks", 0, 500, "playlist_id:\(id)", "tags:dalCj"]]
            ]
        }
        let response = await coordinator.sendJSONRPCCommand(request)
        guard let result = response["result"] as? [String: Any] else {
            os_log(.error, log: logger, "❌ Tracks fetch failed for %{public}s", source.title)
            tracks = []
            isLoading = false
            loadFailed = true
            return
        }
        // Album tracks come back under `titles_loop`; playlist tracks under
        // `playlisttracks_loop`.
        let loop = (result["titles_loop"] as? [[String: Any]])
            ?? (result["playlisttracks_loop"] as? [[String: Any]])
            ?? []
        tracks = loop.compactMap(parseTrack)
        isLoading = false
        os_log(.info, log: logger, "✅ Loaded %d tracks for %{public}s", tracks.count, source.title)
    }

    /// Manual dict → `Track` parse. Handles LMS's mixed Int/String id form.
    /// Drops items missing `id` or `title`.
    private func parseTrack(_ raw: [String: Any]) -> Track? {
        let id: String
        if let s = raw["id"] as? String { id = s }
        else if let n = raw["id"] as? Int { id = String(n) }
        else if let n = raw["id"] as? NSNumber { id = n.stringValue }
        else { return nil }

        guard let title = raw["title"] as? String, !title.isEmpty else { return nil }

        return Track(
            id: id,
            title: title,
            artist: (raw["artist"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            album: (raw["album"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            coverID: (raw["coverid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Tap-to-play (play-from-here, atomic)

    /// Load the album or playlist and start at the tapped track in one shot.
    /// `playlistcontrol cmd:load <kind>_id:X play_index:N` — proven atomic in
    /// CarPlay (`CarPlaySceneDelegate.swift:452` and `:2404`).
    private func playFromHere(track: Track, index: Int) {
        os_log(.info, log: logger, "▶️ Play from here: %{public}s [%d]", track.title, index)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [
                settings.playerMACAddress,
                ["playlistcontrol", "cmd:load", source.idParam, "play_index:\(index)"]
            ]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }

    /// Append this single track to the current queue.
    private func addToQueue(track: Track) {
        os_log(.info, log: logger, "➕ Add to queue: %{public}s", track.title)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [
                settings.playerMACAddress,
                ["playlistcontrol", "cmd:add", "track_id:\(track.id)"]
            ]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
