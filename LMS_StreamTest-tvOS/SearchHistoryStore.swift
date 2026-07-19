import Foundation

/// Persists the most recent dictated search queries for the tvOS Search tab.
///
/// 20-item ring buffer in UserDefaults. `add(query:)` deduplicates (a re-used
/// query moves to the front, length unchanged), trims whitespace, and rejects
/// empty input. `all()` returns most-recent-first. `clear()` empties.
///
/// Mirrors lms-material/search-field.js:206-216 history shape. v2 follow-up
/// (D7 deferred) will add a "Clear search history" UI; the v1 ship just
/// auto-prunes at the cap.
enum SearchHistoryStore {
    static let cap = 20

    private static let defaultsKey = "tvos.search.history"

    /// Backing store. Production reads/writes `.standard`; tests assign a fresh
    /// `UserDefaults(suiteName: UUID().uuidString)` for isolation.
    static var store: UserDefaults = .standard

    /// Returns the history, most-recent-first. Empty array if none.
    static func all() -> [String] {
        guard let data = store.data(forKey: defaultsKey),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return arr
    }

    /// Appends a query. Empty/whitespace-only input is a no-op. If the query already
    /// exists in history it moves to the front (no duplicates). History length is
    /// capped at `cap` (oldest evicted first).
    static func add(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var history = all()
        history.removeAll { $0 == trimmed }
        history.insert(trimmed, at: 0)
        if history.count > cap {
            history = Array(history.prefix(cap))
        }
        save(history)
    }

    /// Empties the history.
    static func clear() {
        store.removeObject(forKey: defaultsKey)
    }

    private static func save(_ history: [String]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        store.set(data, forKey: defaultsKey)
    }
}
