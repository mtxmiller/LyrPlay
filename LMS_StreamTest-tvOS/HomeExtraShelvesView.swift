import SwiftUI

/// Library tab's PRIMARY content view when Material Skin is installed on the
/// LMS server. Renders one `HomeExtraShelf` per non-empty `HomeExtraSection`
/// from a parsed `["material-skin", "home-extra"]` response — built-in sorts
/// plus any enabled plugin-contributed (`home-extra-3rdparty`) shelves.
///
/// Owns the drill-in `.fullScreenCover` state on behalf of the shelves
/// (matches SearchView's 98q.8 D4=A pattern — the screen-root view holds the
/// cover state, leaf views deliver the target via closure):
/// - artist tiles → `ArtistDetailView`
/// - plugin (`.jive`) tiles → `JiveBrowseView`, recursive via the
///   `navigationDestination(for: JiveCommand.self)` at the stack root.
///
/// Pure rendering — fetch + parse + route to this view vs the fallback view
/// is `LibraryView`'s responsibility.
struct HomeExtraShelvesView: View {
    let sections: [HomeExtraSection]
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var selectedArtist: Artist? = nil
    /// The root browse target — set by a shelf tile tap, drives the
    /// `.fullScreenCover` presentation. Cleared on `closeBrowse`.
    @State private var browseRoot: BrowseDestination? = nil
    /// Drill path inside the plugin-browse cover. Holds the levels pushed
    /// *after* the root. Reset on close. `[BrowseDestination]` because the
    /// cover hosts both plugin (`.plugin`) drills and built-in (`.albumTracks`
    /// / `.playlistTracks`) drills on the same stack — one navigation
    /// contract, one Back semantics.
    @State private var jivePath: [BrowseDestination] = []

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
                        },
                        onBrowseTap: { destination in
                            browseRoot = destination
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
        .fullScreenCover(item: $browseRoot) { destination in
            NavigationStack(path: $jivePath) {
                destinationView(for: destination)
                    .navigationDestination(for: BrowseDestination.self) { next in
                        destinationView(for: next)
                    }
            }
            // pd1 fix: the cover's exit handler ONLY fires at the root level
            // (jivePath empty). At deeper levels, SwiftUI's NavigationStack
            // pops one level natively per Menu press. The previous
            // unconditional handler stole every Menu press and collapsed the
            // whole stack.
            .onExitCommand {
                if jivePath.isEmpty {
                    closeBrowse()
                } else {
                    jivePath.removeLast()
                }
            }
        }
    }

    /// Resolve a `BrowseDestination` to the view that renders it. Each case is
    /// a different drill — plugin browse vs built-in track list — but they
    /// share one stack.
    @ViewBuilder
    private func destinationView(for destination: BrowseDestination) -> some View {
        switch destination {
        case .plugin(let command):
            JiveBrowseView(
                command: command,
                coordinator: coordinator,
                settings: settings,
                path: $jivePath,
                dismissBrowse: closeBrowse
            )
        case .albumTracks(let albumID, let title):
            BuiltinTrackListView(
                source: .album(id: albumID, title: title),
                coordinator: coordinator,
                settings: settings
            )
        case .playlistTracks(let playlistID, let title):
            BuiltinTrackListView(
                source: .playlist(id: playlistID, title: title),
                coordinator: coordinator,
                settings: settings
            )
        case .favoritesFolder(let itemID, _):
            FavoritesFolderView(
                itemID: itemID,
                coordinator: coordinator,
                settings: settings,
                path: $jivePath
            )
        }
    }

    /// Dismiss the plugin-browse cover and clear the drill path so the next
    /// shelf tap starts fresh. Passed to `JiveBrowseView` as `dismissBrowse`
    /// (`nextWindow: nowplaying` / `home`) and fired by the MENU button at
    /// the root level of the stack.
    private func closeBrowse() {
        browseRoot = nil
        jivePath = []
    }
}

// `BrowseDestination` needs Identifiable so it can drive a `.fullScreenCover(item:)`.
// We synthesize an identity per case + associated values — sufficient for the
// "cover open / cover closed" distinction the host needs.
extension BrowseDestination: Identifiable {
    var id: String {
        switch self {
        case .plugin(let cmd): return "plugin:\(cmd.id.uuidString)"
        case .albumTracks(let aid, _): return "album:\(aid)"
        case .playlistTracks(let pid, _): return "playlist:\(pid)"
        case .favoritesFolder(let fid, _): return "favfolder:\(fid)"
        }
    }
}
