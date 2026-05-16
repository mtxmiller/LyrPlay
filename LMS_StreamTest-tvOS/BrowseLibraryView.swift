import SwiftUI

/// Library tab's FALLBACK view when Material Skin is not installed on the
/// LMS server. Renders a hardcoded list of canonical library categories
/// (Albums / Artists / Genres / New Music / Playlists) — each drills into
/// the existing AlbumListView/ArtistListView/GenreListView/PlaylistsView.
///
/// Why hardcoded vs recursive: live testing against a real LMS server
/// (192.168.1.8) revealed that `["browselibrary", "items"]` at the root
/// times out and only returns useful data with a specific `mode:` param.
/// The actual menu shapes vary by mode (simple `loop_loop` without menu:1,
/// Jive `item_loop` with base+commonParams when menu:1 is present), so a
/// generic recursive renderer would need a significantly more complex
/// parser. The hardcoded categories cover the same 90% of value with one
/// known wire shape per leaf. Extended Browse Modes and plugin nodes are
/// deferred to v2 (see bd `LMS_StreamTest-4vw` notes for the v2 follow-up).
struct BrowseLibraryView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    enum Category: String, CaseIterable, Identifiable, Hashable {
        case albums
        case artists
        case genres
        case newMusic
        case playlists

        var id: String { rawValue }

        var title: String {
            switch self {
            case .albums:    return "Albums"
            case .artists:   return "Artists"
            case .genres:    return "Genres"
            case .newMusic:  return "New Music"
            case .playlists: return "Playlists"
            }
        }

        var symbol: String {
            switch self {
            case .albums:    return "opticaldisc"
            case .artists:   return "person.2.fill"
            case .genres:    return "music.note.list"
            case .newMusic:  return "sparkles"
            case .playlists: return "music.note.list"
            }
        }
    }

    @State private var selectedCategory: Category? = nil

    var body: some View {
        TVList {
            ForEach(Category.allCases) { category in
                Button {
                    selectedCategory = category
                } label: {
                    MediaRow(
                        primary: category.title,
                        secondary: nil,
                        artworkURL: nil,
                        placeholderSymbol: category.symbol
                    )
                }
                .buttonStyle(.plain)
                .tvListRow()
            }
        }
        .navigationTitle("Library")
        .navigationDestination(item: $selectedCategory) { category in
            destination(for: category)
        }
    }

    @ViewBuilder
    private func destination(for category: Category) -> some View {
        switch category {
        case .albums:
            AlbumListView(
                coordinator: coordinator,
                settings: settings,
                sort: .alphabetical
            )
            .navigationTitle("Albums")
        case .artists:
            ArtistListView(coordinator: coordinator, settings: settings)
        case .genres:
            GenreListView(coordinator: coordinator, settings: settings)
        case .newMusic:
            AlbumListView(
                coordinator: coordinator,
                settings: settings,
                sort: .new
            )
            .navigationTitle("New Music")
        case .playlists:
            PlaylistsView(coordinator: coordinator, settings: settings)
                .navigationTitle("Playlists")
        }
    }
}
