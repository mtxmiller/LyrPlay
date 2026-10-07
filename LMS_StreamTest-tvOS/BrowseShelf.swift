import SwiftUI

/// "Browse" row at the top of the Material shelves screen (bd zxy7, GH #104).
/// One tile per `BrowseLibraryView.Category` — the same full library lists
/// the no-Material fallback menu opens. Without it, a server with Material
/// installed only offered the curated shelves, with no way to reach every
/// artist or album.
///
/// Layout matches `HomeExtraShelf` (header + horizontal tiles, same margins
/// and spacing) so it reads as one more shelf. The tap is hoisted to the
/// parent, which pushes the list onto the Library tab's NavigationStack.
struct BrowseShelf: View {
    let onSelect: (BrowseLibraryView.Category) -> Void

    // Same values as HomeExtraShelf — see the tuning notes there.
    private static let tileSpacing: CGFloat = 48
    private static let horizontalMargin: CGFloat = 80
    private static let scrollVerticalPadding: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "square.grid.2x2")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .frame(width: 36, height: 36)
                Text("Browse")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, Self.horizontalMargin)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Self.tileSpacing) {
                    ForEach(BrowseLibraryView.Category.allCases) { category in
                        MediaTile(
                            title: category.title,
                            artworkURL: nil,
                            placeholderSymbol: category.symbol,
                            action: { onSelect(category) }
                        )
                    }
                }
                .padding(.horizontal, Self.horizontalMargin)
                .padding(.vertical, Self.scrollVerticalPadding)
            }
        }
    }
}
