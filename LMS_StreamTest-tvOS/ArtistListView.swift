import SwiftUI
import os.log

/// Alphabetical artist list — used by the Library tab's fallback path
/// (Material absent). Tap an artist → push `ArtistDetailView`, which wraps
/// `AlbumListView(sort: .byArtist)` and lists that artist's albums.
///
/// Fetches `["artists", start, 200, "tags:s"]` (the `s` tag adds sortable_name
/// which the server uses for proper alpha ordering across "The X" variants).
/// Pages in 200 at a time as the user scrolls near the end, up to the
/// server's `count` (bd zxy7 — the full list is reachable from the Material
/// shelves screen's Browse row now, so it must not stop at 200).
struct ArtistListView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var artists: [Artist] = []
    @State private var isLoading: Bool = false
    @State private var hasFetched: Bool = false
    @State private var selectedArtist: Artist? = nil
    /// Server-reported total (`count`). nil until the first page lands.
    @State private var total: Int? = nil
    @State private var isLoadingMore: Bool = false

    private static let pageSize = 200
    /// Start the next page this many rows before the end, so it usually
    /// lands before focus reaches the last row.
    private static let prefetchMargin = 40

    private let logger = OSLog(subsystem: "com.lmsstream", category: "ArtistListView")

    var body: some View {
        Group {
            if isLoading && !hasFetched {
                ProgressView()
                    .scaleEffect(2.0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if artists.isEmpty && hasFetched {
                emptyState
            } else {
                listView
            }
        }
        .navigationTitle("Artists")
        .onAppear { if !hasFetched { fetch(start: 0) } }
        .navigationDestination(item: $selectedArtist) { artist in
            ArtistDetailView(
                artist: artist,
                coordinator: coordinator,
                settings: settings
            )
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No artists")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add music to your LMS library to see it here.")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var listView: some View {
        TVList {
            ForEach(Array(artists.enumerated()), id: \.element.id) { index, artist in
                Button {
                    selectedArtist = artist
                } label: {
                    MediaRow(
                        primary: artist.name,
                        secondary: nil,
                        artworkURL: LMSArtworkURL.maiArtist(id: artist.id, settings: settings),
                        placeholderSymbol: "person.fill"
                    )
                }
                .buttonStyle(.plain)
                .tvListRow()
                .onAppear { loadMoreIfNeeded(at: index) }
            }
        }
    }

    // MARK: - Fetch

    private func loadMoreIfNeeded(at index: Int) {
        guard let total, artists.count < total, !isLoadingMore,
              index >= artists.count - Self.prefetchMargin else { return }
        fetch(start: artists.count)
    }

    private func fetch(start: Int) {
        if start == 0 { isLoading = true } else { isLoadingMore = true }
        // tags:s adds sortable_name — server-side LMS uses it for alpha sort
        // (handles "The Beatles" → "Beatles" correctly).
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["artists", start, Self.pageSize, "tags:s"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { response in
            DispatchQueue.main.async {
                isLoading = false
                isLoadingMore = false
                hasFetched = true
                guard let result = response["result"] as? [String: Any] else {
                    // A failed later page leaves `total` as-is, so scrolling
                    // near the end again retries it.
                    os_log(.error, log: logger, "❌ Artists fetch (start %d): invalid response", start)
                    return
                }
                // Drop a page that no longer lines up (a retry raced it).
                guard start == artists.count || start == 0 else { return }
                let page = (result["artists_loop"] as? [[String: Any]]).map(Artist.parseLoop) ?? []
                artists = start == 0 ? page : artists + page
                // Stop paging on a short page even if `count` says more.
                total = page.count < Self.pageSize ? artists.count : ((result["count"] as? Int) ?? Int(result["count"] as? String ?? "") ?? artists.count)
                os_log(.info, log: logger, "✅ Artists: %d of %d", artists.count, total ?? 0)
            }
        }
    }
}
