import SwiftUI
import os.log

/// tvOS Library tab — fetches `["material-skin", "home-extra", ...]` and
/// routes to one of three content states based on the response's
/// `material_home` flag:
///
/// - **Material installed + library populated** → `HomeExtraShelvesView`
///   renders curated horizontal-scroll shelves. Built-in sorts plus any
///   plugin-contributed (`home-extra-3rdparty`) shelves the user enabled.
/// - **Material installed + library empty** → "Library is empty" hint.
/// - **Material absent** → `BrowseLibraryView` skin-agnostic browse.
///
/// ## Fetch sequence (plan-eng-review build 9)
///
/// ```
/// .onAppear ─→ probe serverstatus.lastscan
///                │
///                ├─ unchanged + already fetched ─→ reuse cached shelves
///                │
///                └─ changed / first run ─→ performFetch:
///                      registry (if server-token stale)
///                          │
///                          ▼
///                      home-extra ∥ favorites   (async let — parallel)
///                          │
///                          ▼
///                      parse built-ins + plugin objs ─→ render
/// ```
///
/// The `lastscan` probe makes a Library re-entry cheap when the server
/// library has not been rescanned — only `serverstatus` fires, not the
/// full `home-extra`. After an LMS rescan the lastscan changes and the
/// shelves refetch (closes `LMS_StreamTest-3qn`).
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
    @Environment(\.scenePhase) private var scenePhase

    /// Per-fetch `count` param. Material's `NUM_HOME_ITEMS` is the floor (10);
    /// 15 gives slight headroom while keeping the response small.
    private static let homeExtraCount = 15

    /// Max age of cached shelves before an appear refetches even without a
    /// rescan. Plugin shelves change server-side daily with no lastscan
    /// movement (bd 3xn — mherger's stale 1001 Albums tile). The refetch
    /// swaps shelves in place (no spinner), so the only cost is one cheap
    /// JSON-RPC round trip at most once per hour.
    private static let shelfCacheTTL: TimeInterval = 60 * 60

    private let logger = OSLog(subsystem: "com.lmsstream", category: "tvOSLibraryView")

    var body: some View {
        TVScreen(artwork: nowPlaying.currentArtwork) {
            content
        }
        .onAppear {
            Task { await refresh() }
        }
        .onChange(of: settings.enabledLibraryShelves) { _, _ in
            // User toggled shelf selection in Settings — refetch so the new
            // selection takes effect without an app restart or tab cycle.
            // A toggle changes which shelves to request, not library content,
            // so this bypasses the lastscan short-circuit.
            Task { await forceRefetch() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Wake with Library already frontmost doesn't refire onAppear —
            // without this, an app left on this tab overnight keeps stale
            // shelves past the TTL (bd 3xn). refresh() short-circuits inside
            // the TTL, so this is free on quick suspend/resume cycles.
            if phase == .active {
                Task { await refresh() }
            }
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
        // empty. The "I haven't added music yet" case, distinct from "no
        // Material plugin."
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

    // MARK: - Fetch orchestration

    /// Library `.onAppear` entry point. Probes `serverstatus.lastscan`; if
    /// the library has not been rescanned since the last successful fetch,
    /// the cached shelves stand and no `home-extra` request fires.
    @MainActor
    private func refresh() async {
        let token = settings.serverToken
        let lastscan = await probeLastScan()

        if hasFetched, isSettledState,
           let lastscan, settings.lastSeenLastScan[token] == lastscan,
           let fetched = settings.lastShelfFetchDate[token],
           Date().timeIntervalSince(fetched) < Self.shelfCacheTTL {
            os_log(.info, log: logger, "♻️ Library: lastscan unchanged (%lld), cache age %.0fs — reusing cached shelves", lastscan, Date().timeIntervalSince(fetched))
            return
        }
        await performFetch(token: token, lastscan: lastscan)
    }

    /// Shelf-toggle entry point — always refetches `home-extra` (the
    /// selection changed), regardless of lastscan.
    @MainActor
    private func forceRefetch() async {
        let token = settings.serverToken
        let lastscan = await probeLastScan()
        await performFetch(token: token, lastscan: lastscan)
    }

    /// True when `state` holds a fetched result (not the initial spinner).
    private var isSettledState: Bool {
        switch state {
        case .loading: return false
        case .shelves, .emptyLibrary, .browseLibraryFallback: return true
        }
    }

    /// Run the full fetch: refresh the plugin registry if stale for this
    /// server, then `home-extra` ∥ `favorites` in parallel, parse, render.
    /// Every server-dependent step re-checks `token` against the live
    /// `serverToken` and drops its result if the user changed servers
    /// mid-flight (plan-eng-review 1.B / issue #3).
    @MainActor
    private func performFetch(token: String, lastscan: Int64?) async {
        // 1. Plugin registry — refetch only when stale for this server.
        if settings.pluginExtraRegistryToken != token {
            if let registry = await fetchRegistry() {
                guard token == settings.serverToken else {
                    os_log(.info, log: logger, "🚫 Library: server changed during registry fetch — dropping")
                    return
                }
                settings.pluginExtraRegistry = registry
                settings.pluginExtraRegistryToken = token
                settings.reconcilePluginRegistry(registry)
            }
            // Registry fetch failure (nil) — keep any prior registry, proceed.
        }

        // 2. home-extra ∥ favorites (independent — fire concurrently).
        async let homeExtraResult = fetchHomeExtra()
        async let favSection: HomeExtraSection? = wantsFavoritesShelf ? fetchFavorites() : nil
        let result = await homeExtraResult
        let favs = await favSection

        guard token == settings.serverToken else {
            os_log(.info, log: logger, "🚫 Library: server changed during home-extra fetch — dropping")
            return
        }

        // 3. Route + render.
        guard let result else {
            os_log(.error, log: logger, "❌ home-extra: invalid response — BrowseLibraryView fallback")
            state = .browseLibraryFallback
            settings.lastShelfFetchDate[token] = Date()
            hasFetched = true
            return
        }

        let parsed = HomeExtraResponse.parse(result)
        guard parsed.materialInstalled else {
            os_log(.info, log: logger, "ℹ️ home-extra: no material_home flag — BrowseLibraryView fallback")
            state = .browseLibraryFallback
            settings.lastShelfFetchDate[token] = Date()
            hasFetched = true
            return
        }

        let pluginSections = HomeExtraResponse.parsePluginSections(
            result, registry: settings.pluginExtraRegistry
        )
        let merged = parsed.sections + pluginSections + (favs.map { [$0] } ?? [])
        applyShelfState(sections: merged)

        if let lastscan {
            settings.lastSeenLastScan[token] = lastscan
        }
        settings.lastShelfFetchDate[token] = Date()
        hasFetched = true
    }

    /// Settle `state` after merging all shelf sections.
    private func applyShelfState(sections: [HomeExtraSection]) {
        if sections.isEmpty {
            os_log(.info, log: logger, "ℹ️ Library empty (Material installed, all enabled shelves returned no items)")
            state = .emptyLibrary
        } else {
            os_log(.info, log: logger, "✅ Library: %d shelves rendered", sections.count)
            state = .shelves(HomeExtraResponse(materialInstalled: true, sections: sections))
        }
    }

    // MARK: - Individual requests

    /// Probe `serverstatus.lastscan` (epoch seconds). nil on failure or
    /// when the server reports no scan yet — caller then always fetches.
    @MainActor
    private func probeLastScan() async -> Int64? {
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["serverstatus", 0, 0]]
        ]
        let response = await coordinator.sendJSONRPCCommand(request)
        guard let result = response["result"] as? [String: Any] else { return nil }
        // lastscan arrives as a String (epoch) on most LMS builds, Int on some.
        if let s = result["lastscan"] as? String, let v = Int64(s) { return v }
        if let n = result["lastscan"] as? Int { return Int64(n) }
        if let n = result["lastscan"] as? Int64 { return n }
        return nil
    }

    /// Fetch the `home-extra-3rdparty` plugin registry. Returns nil on a
    /// network failure (no `result` dict) so the caller can distinguish
    /// failure from a genuinely-empty registry and skip orphan pruning.
    @MainActor
    private func fetchRegistry() async -> [PluginExtraRegistration]? {
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["material-skin", "home-extra-3rdparty"]]
        ]
        let response = await coordinator.sendJSONRPCCommand(request)
        guard let result = response["result"] as? [String: Any] else { return nil }
        return HomeExtraResponse.parseRegistry(result)
    }

    /// Fetch `home-extra` with built-in sort keys + enabled plugin ids.
    /// Returns the raw `result` dict, or nil on a network failure.
    ///
    /// Uses the connected player's id — plugin shelves with `needsPlayer`
    /// return an empty obj for an empty player_id (verified live).
    @MainActor
    private func fetchHomeExtra() async -> [String: Any]? {
        var cliList: [Any] = ["material-skin", "home-extra"]
        cliList.append(contentsOf: currentSortParams())
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, cliList]
        ]
        let response = await coordinator.sendJSONRPCCommand(request)
        return response["result"] as? [String: Any]
    }

    /// Fire `["favorites","items"]` directly — the simple `loop_loop` shape
    /// `FavoriteItem.parseLoop` already speaks (no `menu:1` Jive shape).
    @MainActor
    private func fetchFavorites() async -> HomeExtraSection? {
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["favorites", "items", 0, Self.homeExtraCount, "want_url:1"]]
        ]
        let response = await coordinator.sendJSONRPCCommand(request)
        guard let result = response["result"] as? [String: Any],
              let loop = result["loop_loop"] as? [[String: Any]] else {
            return nil
        }
        // parseLoop now retains folders; the Library favorites shelf can't drill
        // (LMS_StreamTest-5bs), so hide them here.
        let favs = FavoriteItem.parseLoop(loop).filter { !$0.isFolder }
        guard !favs.isEmpty else { return nil }
        return HomeExtraSection(id: "favorites", title: "Favorites", items: .favorites(favs))
    }

    // MARK: - Request param assembly

    /// Build the `home-extra` request params from the user's shelf
    /// selection: built-in sort keys (`<key>:1`) plus enabled plugin
    /// strippedIDs (`<id>:1`), then `count:N`.
    private func currentSortParams() -> [String] {
        let enabledBuiltins = LibraryShelf.allCases.filter {
            $0.dataSource == .homeExtra
                && settings.enabledLibraryShelves.contains($0.rawValue)
        }
        var params = enabledBuiltins.map(\.requestParam)

        for plugin in settings.pluginExtraRegistry
            where settings.enabledLibraryShelves.contains(plugin.shelfKey) {
            params.append("\(plugin.strippedID):1")
        }

        params.append("count:\(Self.homeExtraCount)")
        return params
    }

    /// True iff the user has the Favorites shelf enabled (the only built-in
    /// shelf fetched separately from home-extra).
    private var wantsFavoritesShelf: Bool {
        settings.enabledLibraryShelves.contains(LibraryShelf.favorites.rawValue)
    }
}
