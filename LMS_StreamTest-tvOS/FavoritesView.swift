import SwiftUI
import os.log

/// Library tab → Favorites sub-view.
///
/// Fetches `["favorites", "items", 0, 100, "want_url:1", "feedMode:1"]` (response key
/// `item_loop` per lms-material server.js:215) and renders the playable items as MediaRows.
/// Folder items are filtered here — this flat view has no drill affordance and is
/// currently UNREFERENCED (the home-extra Favorites shelf + `FavoritesFolderView`
/// below are the live surfaces; folders drill there per `5bs`).
///
/// Tap-to-play stays on the Library tab per D6 (CarPlay convention).
struct FavoritesView: View {
    // Only needs the stateless JSON-RPC seam (98q.13) — no playback control,
    // no child views that require the concrete coordinator.
    let coordinator: any SlimProtoJSONRPCRunner
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
                    // parseLoop retains folders; this flat view can't drill,
                    // so hide them (the shelf path drills — FavoritesFolderView).
                    items = FavoriteItem.parseLoop(loop).filter { !$0.isFolder }
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

// MARK: - Favorites folder drill (LMS_StreamTest-5bs)

/// Drill destination for a favorites folder.
///
/// Pushed onto `HomeExtraShelvesView`'s browse cover stack as
/// `BrowseDestination.favoritesFolder` when a folder tile on the Favorites
/// shelf is selected. Fetches the folder's children with the same wire call
/// CarPlay's folder drill uses (`CarPlaySceneDelegate.fetchFavorites(itemID:)`):
/// `["favorites", "items", 0, 100, "item_id:<id>", "want_url:1"]`. Child
/// folders append another `.favoritesFolder` to the same path — recursive,
/// folder-of-folders supported; Menu pops one level natively (pd1 contract).
/// Playable leaves fire the player-targeted `favorites playlist play`.
struct FavoritesFolderView: View {
    /// The folder's favorites `item_id` — a tree position ("3.0"), not a db id.
    let itemID: String
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager
    /// The enclosing browse cover's `NavigationStack` path — child-folder
    /// drill appends to it.
    @Binding var path: [BrowseDestination]

    @State private var items: [FavoriteItem] = []
    @State private var isLoading: Bool = true
    @State private var loadFailed: Bool = false
    @State private var fetchToken: Int = 0

    private let logger = OSLog(subsystem: "com.lmsstream", category: "FavoritesFolderView")

    var body: some View {
        TVScreen {
            Group {
                if isLoading {
                    ProgressView()
                        .scaleEffect(2.0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed {
                    errorState
                } else if items.isEmpty {
                    emptyState
                } else {
                    listView
                }
            }
        }
        // No navigationTitle — same rationale as BuiltinTrackListView: on a
        // tvOS List root it renders as a large title floating over scrolled
        // content. The user just drilled into this folder.
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
            Image(systemName: "folder")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("Folder is empty")
                .font(.largeTitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        // Identity by array offset — matches FavoritesView (favorite ids are
        // tree positions and aren't guaranteed unique across mixed sources).
        TVList {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    if item.isFolder {
                        path.append(.favoritesFolder(itemID: item.id, title: item.name))
                    } else {
                        playFavorite(item)
                    }
                } label: {
                    MediaRow(
                        primary: item.name,
                        secondary: item.isFolder ? nil : item.type,
                        artworkURL: LMSArtworkURL.favoriteIcon(item.icon, settings: settings),
                        placeholderSymbol: item.isFolder ? "folder.fill" : "star.fill"
                    )
                }
                .buttonStyle(.plain)
                .tvListRow()
            }
        }
    }

    // MARK: - Fetch

    @MainActor
    private func fetch() async {
        isLoading = true
        loadFailed = false
        // System-scoped, id-keyed children of this folder. Do NOT pass
        // "feedMode:1" — the OPML shape has no per-item id, which breaks
        // both drill and play (see FavoritesView.fetch note).
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["favorites", "items", 0, 100, "item_id:\(itemID)", "want_url:1"]]
        ]
        let response = await coordinator.sendJSONRPCCommand(cmd)
        guard let result = response["result"] as? [String: Any] else {
            os_log(.error, log: logger, "❌ Favorites folder %{public}s: invalid response", itemID)
            isLoading = false
            loadFailed = true
            return
        }
        let loop = result["loop_loop"] as? [[String: Any]] ?? []
        // Folders retained — their rows drill another level.
        items = FavoriteItem.parseLoop(loop)
        isLoading = false
        os_log(.info, log: logger, "✅ Favorites folder %{public}s: %d items", itemID, items.count)
    }

    // MARK: - Tap-to-play

    private func playFavorite(_ item: FavoriteItem) {
        os_log(.info, log: logger, "▶️ Play favorite from folder: %{public}s", item.name)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["favorites", "playlist", "play", "item_id:\(item.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
