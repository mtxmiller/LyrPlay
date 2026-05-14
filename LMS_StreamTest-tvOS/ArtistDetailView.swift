import SwiftUI

/// Drill-in target from a Search-results artist row (98q.8 D4=A).
///
/// Wraps `AlbumListView(sort: .byArtist(id: artist.id))` so the album rendering
/// + tap-to-play wiring + lifecycle gating stays in one place. Adds the artist
/// name as the navigation title.
///
/// Presented by the caller via `.fullScreenCover` wrapping a `NavigationStack`
/// (the tvos-nav-push-hides-tabbar 9/10 pattern, same as Queue + Visualizer).
/// The fullScreenCover host owns dismissal via `.onExitCommand`.
struct ArtistDetailView: View {
    let artist: Artist
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    var body: some View {
        TVScreen {
            AlbumListView(
                coordinator: coordinator,
                settings: settings,
                sort: .byArtist(id: artist.id)
            )
        }
        .navigationTitle(artist.name)
    }
}
