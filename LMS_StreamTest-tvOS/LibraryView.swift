import SwiftUI
import os.log

/// tvOS Library tab — fetches `["material-skin", "home-extra", ...]` on
/// appear and routes to one of three content states based on the response's
/// `material_home` flag:
///
/// - **Material installed + library populated** → `HomeExtraShelvesView`
///   renders curated horizontal-scroll shelves of artwork tiles (primary UX,
///   matches what mherger / Elissen see in Material on iPhone).
/// - **Material installed + library empty** → "Library is empty" hint card
///   pointing the user to add music in LMS.
/// - **Material absent** (`material_home` flag missing from response) →
///   `BrowseLibraryView` recursive skin-agnostic browse via core LMS
///   `["browselibrary", "items"]`. Works on every LMS server regardless of
///   skin installation.
///
/// The fetch is `.onAppear`-only — re-entering the Library tab refetches.
/// Matches AlbumListView/FavoritesView's convention (stale-while-on-tab is
/// acceptable; tab re-entry surfaces fresh state).
///
/// Background: tinted artwork blur via TVScreen for visual coherence with
/// Now Playing and Queue (53n decisions stand).
struct LibraryView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var settings: SettingsManager

    private enum State {
        case loading
        case shelves(HomeExtraResponse)        // material installed + items
        case emptyLibrary                       // material installed + all loops empty
        case browseLibraryFallback              // material absent
    }

    @SwiftUI.State private var state: State = .loading
    @SwiftUI.State private var hasFetched: Bool = false

    /// Per-fetch `count` param. Material's `NUM_HOME_ITEMS` is the floor (10);
    /// passing 15 gives slight headroom while keeping the response small.
    /// Random sort fetches 300 internally regardless and returns up to count.
    private static let homeExtraCount = 15

    /// Build the home-extra request params from the user's shelf selection.
    /// Only shelves with `dataSource == .homeExtra` participate; favorites
    /// (the lone `.separateFetch` shelf) is fetched independently.
    private func currentSortParams() -> [String] {
        let enabled = LibraryShelf.allCases.filter {
            $0.dataSource == .homeExtra
                && settings.enabledLibraryShelves.contains($0.rawValue)
        }
        var params = enabled.map(\.requestParam)
        params.append("count:\(Self.homeExtraCount)")
        return params
    }

    /// True iff the user has the Favorites shelf enabled (the only shelf
    /// fetched separately from home-extra).
    private var wantsFavoritesShelf: Bool {
        settings.enabledLibraryShelves.contains(LibraryShelf.favorites.rawValue)
    }

    private let logger = OSLog(subsystem: "com.lmsstream", category: "tvOSLibraryView")

    var body: some View {
        TVScreen(artwork: nowPlaying.currentArtwork) {
            content
        }
        .onAppear { if !hasFetched { fetch() } }
        .onChange(of: settings.enabledLibraryShelves) { _, _ in
            // User toggled shelf selection in Settings — invalidate cached
            // response and refetch so the new selection takes effect without
            // requiring an app restart or tab cycle.
            hasFetched = false
            fetch()
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            loadingView
        case .shelves(let response):
            HomeExtraShelvesView(
                sections: response.sections,
                coordinator: coordinator,
                settings: settings
            )
        case .emptyLibrary:
            emptyLibraryHint
        case .browseLibraryFallback:
            BrowseLibraryView(
                coordinator: coordinator,
                settings: settings
            )
        }
    }

    private var loadingView: some View {
        ProgressView()
            .scaleEffect(2.0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibraryHint: some View {
        // Material is installed (the flag came back) but every shelf was
        // empty. This is the "I haven't added music yet" case, distinct from
        // "no Material plugin." Different empty state, different remedy.
        VStack(spacing: 24) {
            Image(systemName: "music.note.house")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("Library is empty")
                .font(.largeTitle)
            Text("Add music to your LMS library to see it here.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Fetch

    private func fetch() {
        // Build the home-extra CLI request: ["material-skin", "home-extra",
        // "<shelf-key>:1", ..., "count:15"]. Library reads use empty
        // player_id — matches AlbumListView / FavoritesView convention.
        var cliList: [Any] = ["material-skin", "home-extra"]
        cliList.append(contentsOf: currentSortParams())

        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", cliList]
        ]

        coordinator.sendJSONRPCCommandDirect(request) { response in
            DispatchQueue.main.async {
                hasFetched = true
                guard let result = response["result"] as? [String: Any] else {
                    // Network failure or malformed response — treat as "no
                    // Material" so the user still gets a working library via
                    // the skin-agnostic fallback. Worst case is one extra
                    // browselibrary request when the next .onAppear refetches.
                    os_log(.error, log: logger, "❌ home-extra: invalid response, falling back to browselibrary")
                    state = .browseLibraryFallback
                    return
                }

                let parsed = HomeExtraResponse.parse(result)

                if !parsed.materialInstalled {
                    os_log(.info, log: logger, "ℹ️ home-extra: no material_home flag → BrowseLibraryView fallback")
                    state = .browseLibraryFallback
                    return
                }

                // Material installed. If favorites shelf is enabled, chain a
                // second fetch for it before settling state — Material's
                // home-extra returns favorites in Jive shape we don't parse
                // yet, so we hit `["favorites","items"]` directly for the
                // wire shape FavoriteItem.parseLoop already speaks.
                if wantsFavoritesShelf {
                    fetchFavorites { favSection in
                        DispatchQueue.main.async {
                            let merged = parsed.sections + (favSection.map { [$0] } ?? [])
                            applyShelfState(sections: merged)
                        }
                    }
                } else {
                    applyShelfState(sections: parsed.sections)
                }
            }
        }
    }

    /// Settle `state` after merging home-extra + favorites sections. Pulled
    /// out so both the favorites-enabled and favorites-disabled branches
    /// converge cleanly.
    private func applyShelfState(sections: [HomeExtraSection]) {
        if sections.isEmpty {
            os_log(.info, log: logger, "ℹ️ Library empty (Material installed, all enabled shelves returned no items)")
            state = .emptyLibrary
        } else {
            os_log(.info, log: logger, "✅ Library: %d shelves rendered", sections.count)
            state = .shelves(HomeExtraResponse(materialInstalled: true, sections: sections))
        }
    }

    /// Fire `["favorites","items"]` directly. Uses the same wire shape
    /// FavoritesView consumes (no `menu:1` — Jive shape avoided), so the
    /// existing FavoriteItem.parseLoop handles the response unchanged.
    /// Calls completion on a background callback queue with the section or
    /// nil if the fetch failed / returned no playable items.
    private func fetchFavorites(_ completion: @escaping (HomeExtraSection?) -> Void) {
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["favorites", "items", 0, Self.homeExtraCount, "want_url:1"]]
        ]
        coordinator.sendJSONRPCCommandDirect(request) { response in
            guard let result = response["result"] as? [String: Any],
                  let loop = result["loop_loop"] as? [[String: Any]] else {
                completion(nil)
                return
            }
            let favs = FavoriteItem.parseLoop(loop)
            if favs.isEmpty {
                completion(nil)
            } else {
                completion(HomeExtraSection(
                    id: "favorites",
                    title: "Favorites",
                    items: .favorites(favs)
                ))
            }
        }
    }
}
