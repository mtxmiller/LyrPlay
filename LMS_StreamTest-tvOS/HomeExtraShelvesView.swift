import SwiftUI

/// Library tab's PRIMARY content view when Material Skin is installed on the
/// LMS server. Renders one `HomeExtraShelf` per non-empty `HomeExtraSection`
/// from a parsed `["material-skin", "home-extra"]` response.
///
/// Owns the artist drill-in `.fullScreenCover` state on behalf of the
/// shelves (matches SearchView's 98q.8 D4=A pattern — the screen-root view
/// holds the cover state, leaf views deliver the artist via closure).
///
/// Pure rendering — fetch + parse + route to this view vs the fallback view
/// is `LibraryView`'s responsibility.
struct HomeExtraShelvesView: View {
    let sections: [HomeExtraSection]
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var selectedArtist: Artist? = nil

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(sections) { section in
                    HomeExtraShelf(
                        section: section,
                        coordinator: coordinator,
                        settings: settings,
                        onArtistTap: { artist in
                            selectedArtist = artist
                        }
                    )
                }
            }
            .padding(.top, 24)
            .padding(.bottom, 48)
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
    }
}
