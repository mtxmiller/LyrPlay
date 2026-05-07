import Testing
import Foundation
@testable import LMS_StreamTest_tvOS

/// SearchHistoryStore.store is module-static. Mark the suite serialized so
/// tests don't race on it (Swift Testing parallelizes within a suite by default).
@Suite(.serialized)
struct SearchHistoryStoreTests {

    /// Returns (suite, suiteName). Caller passes both into resetStore for cleanup.
    private func makeIsolatedStore() -> (UserDefaults, String) {
        let name = "search-history-test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        SearchHistoryStore.store = suite
        return (suite, name)
    }

    private func resetStore(_ suiteName: String) {
        // Restore .standard FIRST so any concurrent test or assertion failure here
        // can't leave a tainted suite as the global store.
        SearchHistoryStore.store = .standard
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    @Test func emptyByDefault() {
        let (_, name) = makeIsolatedStore()
        defer { resetStore(name) }

        #expect(SearchHistoryStore.all().isEmpty)
    }

    @Test func addThreeMostRecentFirst() {
        let (_, name) = makeIsolatedStore()
        defer { resetStore(name) }

        SearchHistoryStore.add(query: "alpha")
        SearchHistoryStore.add(query: "bravo")
        SearchHistoryStore.add(query: "charlie")

        #expect(SearchHistoryStore.all() == ["charlie", "bravo", "alpha"])
    }

    @Test func duplicateMovesToFrontNoGrowth() {
        let (_, name) = makeIsolatedStore()
        defer { resetStore(name) }

        SearchHistoryStore.add(query: "alpha")
        SearchHistoryStore.add(query: "bravo")
        SearchHistoryStore.add(query: "alpha")  // re-used

        #expect(SearchHistoryStore.all() == ["alpha", "bravo"])
    }

    @Test func capsAt20() {
        let (_, name) = makeIsolatedStore()
        defer { resetStore(name) }

        for i in 1...25 {
            SearchHistoryStore.add(query: "q\(i)")
        }

        let history = SearchHistoryStore.all()
        #expect(history.count == 20)
        #expect(history.first == "q25", "newest at front")
        #expect(history.last == "q6", "oldest 5 (q1-q5) evicted")
    }

    @Test func emptyOrWhitespaceQueryIsNoOp() {
        let (_, name) = makeIsolatedStore()
        defer { resetStore(name) }

        SearchHistoryStore.add(query: "")
        SearchHistoryStore.add(query: "   ")
        SearchHistoryStore.add(query: "\t\n")

        #expect(SearchHistoryStore.all().isEmpty)
    }

    @Test func trimsWhitespaceOnAdd() {
        let (_, name) = makeIsolatedStore()
        defer { resetStore(name) }

        SearchHistoryStore.add(query: "  pink floyd  ")

        #expect(SearchHistoryStore.all() == ["pink floyd"])
    }

    @Test func clearEmptiesHistory() {
        let (_, name) = makeIsolatedStore()
        defer { resetStore(name) }

        SearchHistoryStore.add(query: "alpha")
        SearchHistoryStore.add(query: "bravo")

        SearchHistoryStore.clear()

        #expect(SearchHistoryStore.all().isEmpty)
    }
}
