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
        List {
            ForEach(playlists, id: \.id) { playlist in
                Button {
                    playPlaylist(playlist)
                } label: {
                    MediaRow(
                        primary: playlist.name,
                        secondary: secondaryText(for: playlist),
                        artworkURL: LMSArtworkURL.materialPlaylist(name: playlist.name, settings: settings),
                        placeholderSymbol: "music.note.list"
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
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

    // MARK: - Tap-to-play

    private func playPlaylist(_ playlist: Playlist) {
        // Prefer originalNumericId when LMS gave us one (numeric playlist_id). Fall back to id.
        let playlistID = playlist.originalNumericId.map(String.init) ?? playlist.id
        os_log(.info, log: logger, "▶️ Play playlist: %{public}s (id=%{public}s)", playlist.name, playlistID)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:load", "playlist_id:\(playlistID)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
