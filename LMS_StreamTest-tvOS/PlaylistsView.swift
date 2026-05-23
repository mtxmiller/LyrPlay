import SwiftUI
import os.log

/// Library tab → Playlists sub-view.
///
/// Fetches `["playlists", 0, 1000, "tags:su"]` (matches CarPlay's fetchPlaylists at
/// CarPlaySceneDelegate.swift:698-708; tags s=name, u=url). Playlists are usually <100 even
/// on large libraries; 1000 is a safe ceiling.
///
/// Tap loads + plays the playlist via `playlistcontrol cmd:load playlist_id:N` (CarPlay
/// pattern at CarPlaySceneDelegate.swift:338). User stays on Library per D6.
struct PlaylistsView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var playlists: [Playlist] = []
    @State private var isLoading: Bool = false
    @State private var hasFetched: Bool = false
    /// E1 revised: Select drills into the playlist's tracks. Stored as
    /// `BuiltinTrackListView.Source` so the destination view receives it
    /// directly; .album case is unused here, harmless.
    @State private var selectedDrill: BuiltinTrackListView.Source? = nil

    private let logger = OSLog(subsystem: "com.lmsstream", category: "PlaylistsView")

    var body: some View {
        Group {
            if isLoading && !hasFetched {
                ProgressView()
                    .scaleEffect(2.0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playlists.isEmpty && hasFetched {
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
            Image(systemName: "music.note.list")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No playlists")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Create playlists in LMS Material to see them here.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var listView: some View {
        // Identity by playlist.id: stable, no dupes possible (LMS playlist names are unique).
        TVList {
            ForEach(playlists, id: \.id) { playlist in
                Button {
                    // E1 revised: Select drills into the playlist's tracks
                    // so the user can start from a song.
                    selectedDrill = .playlist(id: playlistDrillID(playlist), title: playlist.name)
                } label: {
                    MediaRow(
                        primary: playlist.name,
                        secondary: secondaryText(for: playlist),
                        artworkURL: LMSArtworkURL.materialPlaylist(name: playlist.name, settings: settings),
                        placeholderSymbol: "music.note.list"
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { playlistContextMenu(for: playlist) }
                .tvListRow()
            }
        }
    }

    /// Press-and-hold menu — Play all / Add all. The default tap drills.
    @ViewBuilder
    private func playlistContextMenu(for playlist: Playlist) -> some View {
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

    /// Numeric playlist_id when LMS gave one; falls back to id. Mirrors the
    /// existing `playPlaylist` resolution.
    private func playlistDrillID(_ playlist: Playlist) -> String {
        playlist.originalNumericId.map(String.init) ?? playlist.id
    }

    private func secondaryText(for playlist: Playlist) -> String? {
        let display = playlist.trackCountDisplay
        return display.isEmpty ? nil : display
    }

    // MARK: - Fetch

    private func fetch() {
        isLoading = true
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["playlists", 0, 1000, "tags:su"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { response in
            DispatchQueue.main.async {
                isLoading = false
                hasFetched = true
                guard let result = response["result"] as? [String: Any] else {
                    os_log(.error, log: logger, "❌ Playlists fetch: invalid response")
                    return
                }
                if let loop = result["playlists_loop"] as? [[String: Any]] {
                    playlists = Playlist.parseLoop(loop)
                } else {
                    playlists = []
                }
                os_log(.info, log: logger, "✅ Playlists: %d items", playlists.count)
            }
        }
    }

    // MARK: - Whole-playlist actions (press-and-hold menu only)

    private func playPlaylist(_ playlist: Playlist) {
        let playlistID = playlistDrillID(playlist)
        os_log(.info, log: logger, "▶️ Play playlist (Play All): %{public}s (id=%{public}s)", playlist.name, playlistID)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:load", "playlist_id:\(playlistID)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }

    private func addPlaylist(_ playlist: Playlist) {
        let playlistID = playlistDrillID(playlist)
        os_log(.info, log: logger, "➕ Add playlist: %{public}s (id=%{public}s)", playlist.name, playlistID)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:add", "playlist_id:\(playlistID)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
