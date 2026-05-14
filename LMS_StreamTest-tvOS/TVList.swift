import SwiftUI

/// `List` wrapper for tvOS browse and settings screens.
///
/// Bakes in the correct list style per screen kind and pairs with the
/// `.tvListRow()` row modifier, which gives every row an opaque fill. On tvOS
/// the focus engine scales the focused row up slightly; with the previous
/// `.listRowBackground(Color.clear)` the scaled row composited against its
/// neighbors, producing the scroll "flicker"/overlap (mherger beta feedback
/// #1). An opaque fill makes the scaled focused row cleanly cover instead of
/// blend.
///
/// Used inside a `TVScreen` — the screen root supplies the backdrop, `TVList`
/// supplies opaque rows on top of it. Adopt across every tvOS `List`:
/// FavoritesView, AlbumListView, SearchView, PlaylistsView, QueueView,
/// SettingsView (+ its FormatPickerView).
struct TVList<Content: View>: View {
    /// Which kind of list this is. Controls list style only — the opaque row
    /// fill from `.tvListRow()` is universal.
    enum Style {
        /// Browse / media lists (Favorites, AlbumList, Search, Playlists,
        /// Queue) — `.plain`, matching what those views already used.
        case media
        /// Settings list — `.automatic`, preserving SettingsView's existing
        /// grouped appearance. Forcing `.plain` on a settings/control list
        /// would change its look for no reason (plan-eng-review D5).
        case settings
    }

    var style: Style
    @ViewBuilder var content: () -> Content

    init(_ style: Style = .media, @ViewBuilder content: @escaping () -> Content) {
        self.style = style
        self.content = content
    }

    var body: some View {
        Group {
            switch style {
            case .media:
                List { content() }.listStyle(.plain)
            case .settings:
                List { content() }.listStyle(.automatic)
            }
        }
    }
}

extension View {
    /// Opaque row treatment for rows inside a `TVList`. Replaces
    /// `.listRowBackground(Color.clear)`.
    ///
    /// The fill must be opaque, not a translucent material — a material still
    /// composites whatever is behind it, which is the exact failure mode the
    /// focus-scaled row hits. `Color.tvListRowBackground` is the single tuning
    /// point.
    func tvListRow() -> some View {
        listRowBackground(Color.tvListRowBackground)
    }
}

extension Color {
    /// Opaque fill for `TVList` rows. Near-solid dark so rows read as a surface
    /// on top of the `TVScreen` backdrop while the focus-scaled row still
    /// covers its neighbors cleanly. This is the one place to tune the row
    /// look — soften the opacity here if the list reads too heavy on-device.
    static let tvListRowBackground = Color.black.opacity(0.92)
}
