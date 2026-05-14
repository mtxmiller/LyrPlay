import SwiftUI

/// Library tab root. Hosts a four-segment Picker(.segmented) that switches between
/// Favorites, Recently Played albums, New Music albums, and Playlists.
///
/// Decisions: D2 sub-tabs inside Library / D4 Picker(.segmented) / D8 four-segment scope
/// matching CarPlay's home menu (minus Resume + Random + Refresh).
///
/// Background: tinted artwork blur to match Now Playing + Queue visual coherence.
struct LibraryView: View {
    let coordinator: SlimProtoCoordinator
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var settings: SettingsManager

    enum Section: Int, CaseIterable, Hashable {
        case favorites
        case recentlyPlayed
        case newMusic
        case playlists

        var label: String {
            switch self {
            case .favorites: return "Favorites"
            case .recentlyPlayed: return "Recently Played"
            case .newMusic: return "New Music"
            case .playlists: return "Playlists"
            }
        }
    }

    @State private var selectedSection: Section = .favorites

    var body: some View {
        TVScreen(artwork: nowPlaying.currentArtwork) {
            VStack(spacing: 0) {
                picker

                content
            }
        }
    }

    // MARK: - Picker

    private var picker: some View {
        Picker("Library section", selection: $selectedSection) {
            ForEach(Section.allCases, id: \.self) { section in
                Text(section.label).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 80)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .favorites:
            FavoritesView(coordinator: coordinator, settings: settings)
        case .recentlyPlayed:
            AlbumListView(
                coordinator: coordinator,
                settings: settings,
                sort: .recentlyPlayed
            )
        case .newMusic:
            AlbumListView(
                coordinator: coordinator,
                settings: settings,
                sort: .new
            )
        case .playlists:
            PlaylistsView(coordinator: coordinator, settings: settings)
        }
    }

}
