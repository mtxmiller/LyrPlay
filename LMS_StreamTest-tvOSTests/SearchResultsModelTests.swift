import Testing
import Foundation
@testable import LMS_StreamTest_tvOS

/// Tests for `SearchResultsModel` — the per-domain search fan-out + D5=B
/// UUID cancellation token extracted from SearchView (98q.13). Before this,
/// the stale-response guard was verified only via OSLog inspection during
/// hardware /review; a regression (e.g. await hoisting past the token check)
/// would have shipped silently.
///
/// The mock captures completions instead of completing inline, so tests can
/// deliver responses late and out of order — the exact race the token guards.
@MainActor
struct SearchResultsModelTests {

    /// Captures every fan-out call; tests complete them manually.
    final class MockRunner: SlimProtoJSONRPCRunner {
        /// (domain, completion) in arrival order — 4 per fireSearch:
        /// artists, albums, tracks, playlists.
        private(set) var pending: [(domain: String, complete: ([String: Any]) -> Void)] = []

        func sendJSONRPCCommandDirect(_ jsonRPC: [String: Any], completion: @escaping ([String: Any]) -> Void) {
            // params: ["", ["<domain>", 0, 25, ...]] — inner array head names the domain.
            let domain = ((jsonRPC["params"] as? [Any])?.last as? [Any])?.first as? String ?? "?"
            pending.append((domain, completion))
        }
    }

    /// A minimal LMS response for the given domain with one named item.
    /// Tracks/playlists decode via Codable with more required fields than this
    /// test needs — they get empty results; artists/albums carry the payload.
    private func response(for domain: String, name: String) -> [String: Any] {
        switch domain {
        case "artists": return ["result": ["artists_loop": [["id": "1", "artist": name]]]]
        case "albums": return ["result": ["albums_loop": [["id": "1", "album": name]]]]
        default: return ["result": [String: Any]()]
        }
    }

    /// The model's completions hop through `DispatchQueue.main.async` before
    /// touching state; one more hop sequences the assertions after them.
    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func happyPathLandsResults() async {
        let runner = MockRunner()
        let model = SearchResultsModel(runner: runner)

        model.fireSearch(for: "pink")
        #expect(runner.pending.count == 4)
        #expect(model.inFlight == 4)
        #expect(model.hasFetched == false)

        for call in runner.pending {
            call.complete(response(for: call.domain, name: "Pink Floyd"))
        }
        await drainMainQueue()

        #expect(model.artistResults.map(\.name) == ["Pink Floyd"])
        #expect(model.albumResults.map(\.name) == ["Pink Floyd"])
        #expect(model.inFlight == 0)
        #expect(model.hasFetched == true)
        #expect(model.allResultsEmpty == false)
    }

    @Test func staleResponsesAreDroppedAfterSecondSearch() async {
        let runner = MockRunner()
        let model = SearchResultsModel(runner: runner)

        model.fireSearch(for: "first")
        let firstBatch = runner.pending
        #expect(firstBatch.count == 4)

        // Second search fires before the first one's responses arrive.
        model.fireSearch(for: "second")
        #expect(runner.pending.count == 8)
        #expect(model.inFlight == 4)  // reset per fan-out, not cumulative

        // First search's responses arrive late — every one must be dropped.
        for call in firstBatch {
            call.complete(response(for: call.domain, name: "Stale"))
        }
        await drainMainQueue()

        #expect(model.artistResults.isEmpty)
        #expect(model.albumResults.isEmpty)
        #expect(model.inFlight == 4)  // stale guard bails before completeOne
        #expect(model.hasFetched == false)

        // Second search's responses land normally.
        for call in runner.pending.suffix(4) {
            call.complete(response(for: call.domain, name: "Fresh"))
        }
        await drainMainQueue()

        #expect(model.artistResults.map(\.name) == ["Fresh"])
        #expect(model.albumResults.map(\.name) == ["Fresh"])
        #expect(model.inFlight == 0)
        #expect(model.hasFetched == true)
    }

    @Test func resetClearsResultsAndGates() async {
        let runner = MockRunner()
        let model = SearchResultsModel(runner: runner)

        model.fireSearch(for: "pink")
        for call in runner.pending {
            call.complete(response(for: call.domain, name: "Pink Floyd"))
        }
        await drainMainQueue()
        #expect(model.allResultsEmpty == false)

        model.reset()
        #expect(model.allResultsEmpty == true)
        #expect(model.hasFetched == false)
        #expect(model.inFlight == 0)

        // A response surviving past reset() must also be dropped: reset is not
        // a new token, but the next fireSearch issues one; simulate the common
        // backspace-then-retype flow.
        model.fireSearch(for: "queen")
        let staleBatch = runner.pending.suffix(4)
        model.reset()
        model.fireSearch(for: "abba")
        for call in staleBatch {
            call.complete(response(for: call.domain, name: "Queen"))
        }
        await drainMainQueue()
        #expect(model.artistResults.isEmpty)  // queen's responses were stale
    }
}
