import SwiftUI
import os.log

/// Search tab root (98q.8).
///
/// Per locked execution plan:
/// - D1=A: per-domain JSON-RPC fan-out (artists/albums/tracks/playlists), reuses
///   98q.9 parsers (Artist.parseLoop / Album.parseLoop / Playlist.parseLoop /
///   PlaylistTrack.parseLoop). Mirrors lms-material/search-field.js:182-192.
/// - D2=C: starts with SwiftUI .searchable as a hardware smoke test for Siri
///   Remote dictation. If hardware verification shows .searchable does NOT fire
///   dictation on tvOS 26, swap to UISearchController + UIViewControllerRepresentable
///   in a follow-up commit.
/// - D3=A: sectioned single screen (Artists / Albums / Tracks / Playlists).
///   Empty sections suppressed. Matches Material UI + tvOS Music app shape.
/// - D4=A: artist tap → ArtistDetailView via .fullScreenCover wrapping a
///   NavigationStack (tvos-nav-push-hides-tabbar 9/10).
/// - D5=B: 500ms debounce + UUID cancellation token. Stale responses dropped.
///   Matches lms-material/search-field.js:168 timing exactly.
/// - D6=B: 25 results per domain (matches lms-material LMS_INITIAL_SEARCH_RESULTS).
/// - D7=B: pre-search shows 20-item recent-search history; first-launch (empty
///   history) falls back to a centered hint card.
struct SearchView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var searchTerm: String = ""

    // Per-domain results + lifecycle gates + D5=B cancellation token, extracted
    // to a testable model (98q.13). The view owns debounce + history + drill-in;
    // the model owns the fan-out and the stale-response guard.
    @StateObject private var results: SearchResultsModel

    // Debounce timer.
    @State private var debounceTask: Task<Void, Never>? = nil

    // D7=B history list. Loaded on appear; refreshed after each successful query.
    @State private var history: [String] = []

    // D4=A drill-in. fullScreenCover(item:) auto-clears on dismiss.
    @State private var selectedArtist: Artist? = nil
    /// Album / playlist drill-in (build 12 round-2 consistency fix). Same
    /// drill destination as Library tab's AlbumListView / PlaylistsView, but
    /// presented via fullScreenCover here (a NavigationStack push from a
    /// search root would hide the tab bar — tvos-nav-push-hides-tabbar 9/10,
    /// same constraint the artist drill above handles).
    @State private var selectedDrill: BuiltinTrackListView.Source? = nil

    private let logger = OSLog(subsystem: "com.lmsstream", category: "SearchView")
    private let debounceMs: UInt64 = 500_000_000  // 500ms in ns

    init(coordinator: SlimProtoCoordinator, settings: SettingsManager) {
        self.coordinator = coordinator
        _settings = ObservedObject(wrappedValue: settings)
        // The model pins the coordinator captured at first install for this view
        // identity. Safe today because ContentView's server-change path tears the
        // TabView down (isConnected flips false), destroying this identity — if
        // that ever changes, the model keeps firing at the old coordinator.
        _results = StateObject(wrappedValue: SearchResultsModel(runner: coordinator))
    }

    var body: some View {
        TVScreen {
            Group {
                if searchTerm.isEmpty {
                    preSearchView
                } else if results.inFlight > 0 && !results.hasFetched {
                    ProgressView()
                        .scaleEffect(2.0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.allResultsEmpty && results.hasFetched {
                    noResultsView
                } else {
                    resultsView
                }
            }
        }
        .searchable(text: $searchTerm, prompt: "Search music")
        // .searchable on tvOS uses UISearchController which intercepts UIPress
        // events, so HW play/pause press never bubbles up to ContentView's
        // TabView-level handler. Local handler ensures resume-from-paused works
        // here too. See ContentView for the asymmetric-MPRC explanation.
        .onPlayPauseCommand { coordinator.toggleLockScreenPlayPause() }
        .onChange(of: searchTerm) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onAppear {
            history = SearchHistoryStore.all()
        }
        .onDisappear {
            // Cancel any pending debounce so a tab switch mid-debounce doesn't fire 4
            // unnecessary JSON-RPC requests against a model nobody is rendering.
            debounceTask?.cancel()
        }
        .fullScreenCover(item: $selectedArtist) { artist in
            NavigationStack {
                ArtistDetailView(
                    artist: artist,
                    coordinator: coordinator,
                    settings: settings
                )
            }
            .onExitCommand { selectedArtist = nil }
        }
        .fullScreenCover(item: $selectedDrill) { source in
            NavigationStack {
                BuiltinTrackListView(
                    source: source,
                    coordinator: coordinator,
                    settings: settings
                )
            }
            .onExitCommand { selectedDrill = nil }
        }
    }

    // MARK: - Sub-views

    private var preSearchView: some View {
        // D7=B: history list if non-empty, else BLANK hint card.
        Group {
            if history.isEmpty {
                emptyHintCard
            } else {
                historyList
            }
        }
    }

    private var emptyHintCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("Search music")
                .font(.largeTitle)
            Text("Press the Siri Remote search button and dictate, or type to search.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 80)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        TVList {
            Section {
                ForEach(history, id: \.self) { term in
                    Button {
                        searchTerm = term
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(term)
                                .font(.title3)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .tvListRow()
                }
            } header: {
                Text("Recent searches").tvSectionHeader()
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("No results")
                .font(.largeTitle)
            Text("Nothing matched \u{201C}\(searchTerm)\u{201D}.")
                .font(.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsView: some View {
        // D3=A: sectioned single screen. Empty sections suppressed.
        // ForEach identity by parsed item id (98q.9 /review hardening).
        TVList {
            if !results.artistResults.isEmpty {
                Section {
                    ForEach(results.artistResults) { artist in
                        Button { tapArtist(artist) } label: {
                            MediaRow(
                                primary: artist.name,
                                secondary: nil,
                                artworkURL: LMSArtworkURL.maiArtist(id: artist.id, settings: settings)
                            )
                        }
                        .buttonStyle(.plain)
                        .tvListRow()
                    }
                } header: {
                    Text("Artists").tvSectionHeader()
                }
            }
            if !results.albumResults.isEmpty {
                Section {
                    ForEach(results.albumResults, id: \.id) { album in
                        Button { tapAlbum(album) } label: {
                            MediaRow(
                                primary: album.name,
                                secondary: album.artist.isEmpty ? nil : album.artist,
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
                } header: {
                    Text("Albums").tvSectionHeader()
                }
            }
            if !results.trackResults.isEmpty {
                Section {
                    ForEach(results.trackResults, id: \.id) { track in
                        Button { tapTrack(track) } label: {
                            MediaRow(
                                primary: track.title,
                                secondary: track.detailText.isEmpty ? nil : track.detailText,
                                artworkURL: LMSArtworkURL.cover(
                                    coverID: track.artworkURL,
                                    fallbackID: track.id,
                                    settings: settings
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .tvListRow()
                    }
                } header: {
                    Text("Tracks").tvSectionHeader()
                }
            }
            if !results.playlistResults.isEmpty {
                Section {
                    ForEach(results.playlistResults, id: \.id) { playlist in
                        Button { tapPlaylist(playlist) } label: {
                            MediaRow(
                                primary: playlist.name,
                                secondary: playlistSecondary(playlist),
                                artworkURL: LMSArtworkURL.materialPlaylist(name: playlist.name, settings: settings),
                                placeholderSymbol: "music.note.list"
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { playlistContextMenu(for: playlist) }
                        .tvListRow()
                    }
                } header: {
                    Text("Playlists").tvSectionHeader()
                }
            }
        }
    }

    private func playlistSecondary(_ playlist: Playlist) -> String? {
        let display = playlist.trackCountDisplay
        return display.isEmpty ? nil : display
    }

    // MARK: - Debounce + fan-out

    private func scheduleSearch(for term: String) {
        debounceTask?.cancel()

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty: reset to pre-search state.
        if trimmed.isEmpty {
            results.reset()
            return
        }

        // Material's effective floor — 1-char queries return everything in the library
        // and are never useful. (search-field.js:176: `if (str.length>1 && ...)`).
        // Reset results so backspacing from "pink" to "p" doesn't leave stale results
        // on screen with the search bar showing "p".
        if trimmed.count < 2 {
            results.reset()
            return
        }

        debounceTask = Task {
            try? await Task.sleep(nanoseconds: debounceMs)
            if Task.isCancelled { return }
            await MainActor.run { fireSearch(for: trimmed) }
        }
    }

    private func fireSearch(for term: String) {
        SearchHistoryStore.add(query: term)
        history = SearchHistoryStore.all()
        results.fireSearch(for: term)
    }

    // MARK: - Tap handlers

    private func tapArtist(_ artist: Artist) {
        os_log(.info, log: logger, "🧑‍🎤 Artist tapped: %{public}s (id=%{public}s)", artist.name, artist.id)
        selectedArtist = artist  // fullScreenCover(item:) presents on non-nil
    }

    /// Build-12 round-2 consistency fix: Select on a search-result album now
    /// drills into its track list (same as Library tab / Home shelf), so the
    /// user can start from any song. "Play all" moves to press-and-hold.
    private func tapAlbum(_ album: Album) {
        os_log(.info, log: logger, "💿 Album tapped (drill): %{public}s (id=%{public}s)", album.name, album.id)
        selectedDrill = .album(id: album.id, title: album.name)
    }

    private func tapTrack(_ track: PlaylistTrack) {
        os_log(.info, log: logger, "🎵 Track tapped: %{public}s (id=%{public}s)", track.title, track.id)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:load", "track_id:\(track.id)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }

    /// Select on a search-result playlist drills into its tracks. "Play all"
    /// moves to press-and-hold.
    private func tapPlaylist(_ playlist: Playlist) {
        let playlistID = playlist.originalNumericId.map(String.init) ?? playlist.id
        os_log(.info, log: logger, "📋 Playlist tapped (drill): %{public}s (id=%{public}s)", playlist.name, playlistID)
        selectedDrill = .playlist(id: playlistID, title: playlist.name)
    }

    // MARK: - Press-and-hold context menus (whole-collection actions)

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

    private func playAlbum(_ album: Album) {
        os_log(.info, log: logger, "▶️ Play album (Play All): %{public}s (id=%{public}s)", album.name, album.id)
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

    private func playPlaylist(_ playlist: Playlist) {
        let playlistID = playlist.originalNumericId.map(String.init) ?? playlist.id
        os_log(.info, log: logger, "▶️ Play playlist (Play All): %{public}s (id=%{public}s)", playlist.name, playlistID)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:load", "playlist_id:\(playlistID)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }

    private func addPlaylist(_ playlist: Playlist) {
        let playlistID = playlist.originalNumericId.map(String.init) ?? playlist.id
        os_log(.info, log: logger, "➕ Add playlist: %{public}s (id=%{public}s)", playlist.name, playlistID)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlistcontrol", "cmd:add", "playlist_id:\(playlistID)"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in }
    }
}
