import SwiftUI
import os.log

/// Alphabetical genre list — used by the Library tab's fallback path
/// (Material absent). Tap a genre → push `AlbumListView(sort: .byGenre)`
/// which lists albums tagged with that genre.
///
/// Fetches `["genres", 0, 200]` — small list per LMS server (typical ~50-150).
struct GenreListView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var genres: [Genre] = []
    @State private var isLoading: Bool = false
    @State private var hasFetched: Bool = false
    @State private var selectedGenre: Genre? = nil

    private let logger = OSLog(subsystem: "com.lmsstream", category: "GenreListView")

    var body: some View {
        Group {
            if isLoading && !hasFetched {
                ProgressView()
                    .scaleEffect(2.0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if genres.isEmpty && hasFetched {
                emptyState
            } else {
                listView
            }
        }
        .navigationTitle("Genres")
        .onAppear { if !hasFetched { fetch() } }
        .navigationDestination(item: $selectedGenre) { genre in
            AlbumListView(
                coordinator: coordinator,
                settings: settings,
                sort: .byGenre(id: genre.id, name: genre.name)
            )
            .navigationTitle(genre.name)
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No genres")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var listView: some View {
        TVList {
            ForEach(genres, id: \.id) { genre in
                Button {
                    selectedGenre = genre
                } label: {
                    MediaRow(
                        primary: genre.name,
                        secondary: nil,
                        artworkURL: nil,
                        placeholderSymbol: "music.note"
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
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["genres", 0, 200]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { response in
            DispatchQueue.main.async {
                isLoading = false
                hasFetched = true
                guard let result = response["result"] as? [String: Any] else {
                    os_log(.error, log: logger, "❌ Genres fetch: invalid response")
                    return
                }
                if let loop = result["genres_loop"] as? [[String: Any]] {
                    genres = Genre.parseLoop(loop)
                } else {
                    genres = []
                }
                os_log(.info, log: logger, "✅ Genres: %d items", genres.count)
            }
        }
    }
}
