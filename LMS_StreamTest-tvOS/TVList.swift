import SwiftUI

/// `List` wrapper for tvOS browse and settings screens.
///
/// Bakes in the correct list style per screen kind (`.plain` for media lists,
/// `.automatic` for settings) so every tvOS list is consistent, and pairs with
/// the `.tvListRow()` row modifier — the single named hook for row styling.
///
/// Used inside a `TVScreen`: the screen root supplies the opaque backdrop,
/// `TVList` keeps the list itself consistent on top of it. Adopt across every
/// tvOS `List`: FavoritesView, AlbumListView, SearchView, PlaylistsView,
/// QueueView, SettingsView (+ its FormatPickerView).
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
    /// Row treatment for rows inside a `TVList`. The single, named hook for
    /// list-row styling — replaces the scattered `.listRowBackground(Color.clear)`
    /// calls so any future row tuning lives in one place.
    func tvListRow() -> some View {
        listRowBackground(Color.tvListRowBackground)
    }

    /// Section-header treatment for `Section { } header:` blocks inside a
    /// `TVList`. Adds vertical clearance so the tvOS focus engine's scale +
    /// glow on an adjacent row doesn't ride into the header text — from the
    /// section's own first row below, or the previous section's last row above.
    ///
    /// Hardware-only bug: Apple TV overscan tightens the layout enough that
    /// a focused row overlaps the header next to it; the simulator masks it.
    /// Same class of issue as the build-7 `7247206` Library-picker fix.
    /// Applied to every `Section` header that sits between focusable rows
    /// (SearchView result sections, SettingsView's section headers).
    func tvSectionHeader() -> some View {
        self.padding(.vertical, Self.tvSectionHeaderClearance)
    }

    /// Vertical clearance for `tvSectionHeader()`. 16pt covers the focused
    /// row's ~1.10x scale lift plus the focus-glow shadow radius at the
    /// MediaRow heights used in tvOS lists.
    private static var tvSectionHeaderClearance: CGFloat { 16 }
}

extension Color {
    /// Row fill for `TVList` rows. `.clear` — rows are transparent and the tvOS
    /// focus engine's own (inset, rounded) highlight does the visual work,
    /// matching the native tvOS list look.
    ///
    /// An opaque fill was tried first, to stop the focus-scaled row compositing
    /// against its neighbors during scroll (mherger beta feedback #1). It read
    /// as a heavy column of full-bleed boxes that fought the inset/rounded
    /// focus highlight, so it was reverted. If scroll overlap resurfaces, fix
    /// it with row spacing — not an opaque fill. This stays the single tuning
    /// point either way.
    static let tvListRowBackground = Color.clear
}
