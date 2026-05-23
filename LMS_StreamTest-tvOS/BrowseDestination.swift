import Foundation

/// One entry on the plugin-browse `.fullScreenCover` navigation path
/// (`HomeExtraShelvesView.jivePath`).
///
/// The home shelves cover hosts two kinds of drill:
/// - **Plugin SlimBrowse drill** — `JiveBrowseView` rendering the response of
///   a `slim.request` (e.g. Bandcamp folder → folder → tracks).
/// - **Built-in album / playlist drill** — `BuiltinTrackListView` rendering
///   the tracks of a library album or saved playlist (round-4 `ejc` fix).
///
/// One stack, two destinations. The cover declares a single
/// `navigationDestination(for: BrowseDestination.self)` that switches on the
/// case. `Hashable` (by case + associated values) so SwiftUI's
/// `NavigationStack` can use it as the path element type.
///
/// `pd1` Back-button behavior: SwiftUI's `NavigationStack(path:)` pops one
/// level per Menu press natively as long as the cover's `.onExitCommand`
/// doesn't override it. The cover's exit handler is gated on
/// `jivePath.isEmpty` so per-level pop works regardless of which case is on top.
enum BrowseDestination: Hashable {
    /// Plugin SlimBrowse drill — push a `JiveBrowseView(command:)`.
    case plugin(JiveCommand)
    /// Built-in album track list — push a `BuiltinTrackListView` keyed by
    /// `album_id` with the album's display title for the nav bar.
    case albumTracks(albumID: String, title: String)
    /// Built-in playlist track list — push a `BuiltinTrackListView` keyed by
    /// `playlist_id` with the playlist's display name for the nav bar.
    case playlistTracks(playlistID: String, title: String)
}
