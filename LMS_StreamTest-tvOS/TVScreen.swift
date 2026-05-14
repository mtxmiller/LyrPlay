import SwiftUI

/// Screen-root background container for tvOS.
///
/// Wraps a navigable destination — a TabView tab root or a `fullScreenCover`
/// host — in an opaque backdrop so its content never composites against
/// whatever is behind the screen. Without an opaque screen root, a `.plain`
/// `List` and a `fullScreenCover` both render see-through on tvOS: the view
/// underneath bleeds through (the search-results-behind-ArtistDetail bug) and
/// content draws under the tab bar / picker.
///
/// Adopt at screen roots ONLY: `NowPlayingView`, `SearchView`, `LibraryView`,
/// `SettingsView`, `ArtistDetailView`, `QueueView`. Child views rendered inside
/// a screen root (`FavoritesView`, `AlbumListView`, `PlaylistsView`) must NOT
/// wrap their own `TVScreen` — they would nest a second backdrop inside the
/// parent's. Per-list-row opacity is `TVList`'s job, not this.
///
/// Replaces the per-view `background` ZStack that `NowPlayingView`, `QueueView`,
/// and `LibraryView` each carried as a near-duplicate.
struct TVScreen<Content: View>: View {
    /// Now-playing artwork for the blurred backdrop. When `nil`, the backdrop is
    /// solid black — the correct treatment for browse/search screens that have
    /// no track context.
    var artwork: UIImage?

    @ViewBuilder var content: () -> Content

    init(artwork: UIImage? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.artwork = artwork
        self.content = content
    }

    var body: some View {
        content()
            // Fill the screen so the backdrop fills behind it. Content that
            // already self-frames (NowPlayingView's .topLeading fill) is
            // unaffected — it is already max-sized, so this wrapping frame is
            // a no-op for it. List-based content gets stretched to fill.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { backdrop.ignoresSafeArea() }
    }

    private var backdrop: some View {
        ZStack {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                Color.black
            }
        }
    }
}
