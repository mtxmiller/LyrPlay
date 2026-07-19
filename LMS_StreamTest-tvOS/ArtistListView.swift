import SwiftUI
import os.log

/// Alphabetical artist list — used by the Library tab's fallback path
/// (Material absent). Tap an artist → push `ArtistDetailView`, which wraps
/// `AlbumListView(sort: .byArtist)` and lists that artist's albums.
///
/// Fetches `["artists", 0, 200, "tags:s"]` (the `s` tag adds sortable_name
/// which the server uses for proper alpha ordering across "The X" variants).
struct ArtistListView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var artists: [Artist] = []
    @State private var isLoading: Bool = false
    @State private var hasFetched: Bool = false
    @State private var selectedArtist: Artist? = nil

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
        .onAppear { if !hasFetched { fetch() } }
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
            ForEach(artists, id: \.id) { artist in
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
            }
        }
    }

    // MARK: - Fetch

    private func fetch() {
        isLoading = true
        // tags:s adds sortable_name — server-side LMS uses it for alpha sort
        // (handles "The Beatles" → "Beatles" correctly).
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": ["", ["artists", 0, 200, "tags:s"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { response in
            DispatchQueue.main.async {
                isLoading = false
                hasFetched = true
                guard let result = response["result"] as? [String: Any] else {
                    os_log(.error, log: logger, "❌ Artists fetch: invalid response")
                    return
                }
                if let loop = result["artists_loop"] as? [[String: Any]] {
                    artists = Artist.parseLoop(loop)
                } else {
                    artists = []
                }
                os_log(.info, log: logger, "✅ Artists: %d items", artists.count)
            }
        }
    }
}
