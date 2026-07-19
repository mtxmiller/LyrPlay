import Combine
import Foundation
import os.log

/// Per-domain search fan-out + D5=B cancellation token, extracted from
/// SearchView (98q.13) so the stale-response guard is unit-testable against a
/// mocked `SlimProtoJSONRPCRunner` instead of OSLog inspection on hardware.
///
/// Main-thread only, like the view `@State` it replaced: completions marshal
/// to main via `DispatchQueue.main.async` before touching `@Published` state.
final class SearchResultsModel: ObservableObject {
    // Per-domain results.
    @Published private(set) var artistResults: [Artist] = []
    @Published private(set) var albumResults: [Album] = []
    @Published private(set) var trackResults: [PlaylistTrack] = []
    @Published private(set) var playlistResults: [Playlist] = []

    // Lifecycle gates — drive SearchView's spinner / no-results states.
    @Published private(set) var hasFetched: Bool = false
    @Published private(set) var inFlight: Int = 0

    // D5=B cancellation token. Every fan-out gets a fresh UUID; responses with
    // a stale token bail without touching results.
    private var lastQueryToken: UUID = UUID()

    private let runner: any SlimProtoJSONRPCRunner
    private let logger = OSLog(subsystem: "com.lmsstream", category: "SearchResultsModel")
    /// D6=B: 25 results per domain (matches lms-material LMS_INITIAL_SEARCH_RESULTS).
    private let resultLimit = 25

    init(runner: any SlimProtoJSONRPCRunner) {
        self.runner = runner
    }

    var allResultsEmpty: Bool {
        artistResults.isEmpty
            && albumResults.isEmpty
            && trackResults.isEmpty
            && playlistResults.isEmpty
    }

    /// Reset to the pre-search state (empty or sub-2-char query).
    func reset() {
        artistResults = []
        albumResults = []
        trackResults = []
        playlistResults = []
        hasFetched = false
        inFlight = 0
    }

    func fireSearch(for term: String) {
        let token = UUID()
        lastQueryToken = token
        inFlight = 4
        // Don't reset hasFetched here — keep prior results visible while the new
        // query is in flight (Material UI pattern).

        os_log(.info, log: logger, "🔎 Search fan-out for \"%{public}s\" [token=%{public}s]",
               term, token.uuidString)

        fetchArtists(term: term, token: token)
        fetchAlbums(term: term, token: token)
        fetchTracks(term: term, token: token)
        fetchPlaylists(term: term, token: token)
    }

    private func fetchArtists(term: String, token: UUID) {
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["artists", 0, resultLimit, "tags:s", "search:\(term)"]]
        ]
        runner.sendJSONRPCCommandDirect(cmd) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == self.lastQueryToken else {
                    os_log(.info, log: self.logger, "🚫 Stale artists response [token=%{public}s]", token.uuidString)
                    return
                }
                if let result = response["result"] as? [String: Any],
                   let loop = result["artists_loop"] as? [[String: Any]] {
                    self.artistResults = Artist.parseLoop(loop)
                } else {
                    self.artistResults = []
                }
                self.completeOne(label: "artists", count: self.artistResults.count)
            }
        }
    }

    private func fetchAlbums(term: String, token: UUID) {
        // tags:ajly matches AlbumListView (98q.9). The `j` tag returns artwork_track_id
        // which LMSArtworkURL.cover needs — without it, fallback to album.id builds a
        // URL LMS does not serve (album covers live under their first track's id).
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["albums", 0, resultLimit, "tags:ajly", "search:\(term)"]]
        ]
        runner.sendJSONRPCCommandDirect(cmd) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == self.lastQueryToken else {
                    os_log(.info, log: self.logger, "🚫 Stale albums response [token=%{public}s]", token.uuidString)
                    return
                }
                if let result = response["result"] as? [String: Any],
                   let loop = result["albums_loop"] as? [[String: Any]] {
                    self.albumResults = Album.parseLoop(loop)
                } else {
                    self.albumResults = []
                }
                self.completeOne(label: "albums", count: self.albumResults.count)
            }
        }
    }

    private func fetchTracks(term: String, token: UUID) {
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["tracks", 0, resultLimit, "tags:elcy", "search:\(term)"]]
        ]
        runner.sendJSONRPCCommandDirect(cmd) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == self.lastQueryToken else {
                    os_log(.info, log: self.logger, "🚫 Stale tracks response [token=%{public}s]", token.uuidString)
                    return
                }
                if let result = response["result"] as? [String: Any],
                   let loop = result["titles_loop"] as? [[String: Any]] {
                    // LMS tracks query returns `titles_loop` (the row name is "title", not "track").
                    self.trackResults = PlaylistTrack.parseLoop(loop)
                } else {
                    self.trackResults = []
                }
                self.completeOne(label: "tracks", count: self.trackResults.count)
            }
        }
    }

    private func fetchPlaylists(term: String, token: UUID) {
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["playlists", 0, resultLimit, "tags:su", "search:\(term)"]]
        ]
        runner.sendJSONRPCCommandDirect(cmd) { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                guard token == self.lastQueryToken else {
                    os_log(.info, log: self.logger, "🚫 Stale playlists response [token=%{public}s]", token.uuidString)
                    return
                }
                if let result = response["result"] as? [String: Any],
                   let loop = result["playlists_loop"] as? [[String: Any]] {
                    self.playlistResults = Playlist.parseLoop(loop)
                } else {
                    self.playlistResults = []
                }
                self.completeOne(label: "playlists", count: self.playlistResults.count)
            }
        }
    }

    private func completeOne(label: String, count: Int) {
        inFlight = max(0, inFlight - 1)
        hasFetched = true
        os_log(.info, log: logger, "✅ Search %{public}s: %d items (inFlight=%d)",
               label, count, inFlight)
    }
}
