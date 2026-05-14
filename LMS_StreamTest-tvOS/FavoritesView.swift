import SwiftUI
import os.log

/// Library tab → Favorites sub-view.
///
/// Fetches `["favorites", "items", 0, 100, "want_url:1", "feedMode:1"]` (response key
/// `item_loop` per lms-material server.js:215) and renders the playable items as MediaRows.
/// Folder items are filtered by FavoriteItem.parseLoop per D3 flat-flat — see
/// LMS_StreamTest-5bs for the v2 hierarchical-folder follow-up.
///
/// Tap-to-play stays on the Library tab per D6 (CarPlay convention).
struct FavoritesView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var items: [FavoriteItem] = []
    @State private var isLoading: Bool = false
    @State private var hasFetched: Bool = false

    private let logger = OSLog(subsystem: "com.lmsstream", category: "FavoritesView")

    var body: some View {
        Group {
            if isLoading && !hasFetched {
                loadingView
            } else if items.isEmpty && hasFetched {
                emptyState
            } else {
                listView
            }
        }
        .onAppear { if !hasFetched { fetch() } }
    }

    // MARK: - States

    private var loadingView: some View {
        ProgressView()
            .scaleEffect(2.0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "star")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No favorites")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Star items in LMS Material to see them here.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var listView: some View {
        // Identity by array offset: favorite ids can repeat in folder-flattened cases.
        TVList {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    playFavorite(item)
                } label: {
                    MediaRow(
                        primary: item.name,
                        secondary: item.type,
                        artworkURL: LMSArtworkURL.favoriteIcon(item.icon, settings: settings)
                    )
                }
                .buttonStyle(.plain)
                .tvListRow()
            }
        }
    }

    // MARK: - Fetch

    private func fetch() {
        isLoading = true
        // System-scoped query (player MAC not required for the LIST). Cap at 100 — favorites
        // rarely exceed that; if a user reports truncation, raise here and consider pagination.
        //
        // NOTE: do NOT pass "feedMode:1" here. With feedMode:1 the response uses OPML shape
        // (`result.items`, NO `id` field per item) which breaks tap-to-play. Without it, LMS
        // returns the standard list shape: `result.loop_loop` with proper `id` ("cc6ff5a5.0"-style
        // tree positions) usable as `item_id:N` in `favorites playlist play`.
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["favorites", "items", 0, 100, "want_url:1"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { response in
            DispatchQueue.main.async {
                isLoading = false
                hasFetched = true
                guard let result = response["result"] as? [String: Any] else {
                    os_log(.error, log: logger, "❌ Favorites fetch: invalid response")
                    return
                }
                if let loop = result["loop_loop"] as? [[String: Any]] {
                    items = FavoriteItem.parseLoop(loop)
                } else {
                    items = []
                }
                os_log(.info, log: logger, "✅ Favorites: %d items", items.count)
            }
        }
    }

    // MARK: - Tap-to-play

    private func playFavorite(_ item: FavoriteItem) {
        os_log(.info, log: logger, "▶️ Play favorite: %{public}s", item.name)
        // Player-targeted command. `favorites playlist play item_id:N` per lms-material
        // constants.js:279 RADIOS_BASE_ACTIONS. Server broadcasts track-change which updates
        // the Now Playing tab; user remains on Library per D6.
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["favorites", "playlist", "play", "item_id:\(item.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
