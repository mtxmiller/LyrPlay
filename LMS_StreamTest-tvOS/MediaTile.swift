import SwiftUI

/// Square artwork tile for tvOS shelves. Acts as its own focusable Button
/// with a custom scale + shadow focus indicator — replaces the default tvOS
/// halo, which extended unpredictably beyond the tile bounds and overlapped
/// neighbors during shelf traversal (first-look feedback 2026-05-15).
///
/// Uses a fully custom `TileButtonStyle` (below) instead of `.plain`. On
/// tvOS 26, `.buttonStyle(.plain)` + `.focusEffectDisabled()` was NOT
/// enough to suppress the system's white focus card — the card is rendered
/// by the .plain style itself, not by the focus effect, so killing the
/// focus effect leaves it intact. A custom ButtonStyle that returns only
/// `configuration.label` adds no system chrome at all, and the focus
/// indicator becomes purely our scale + shadow tied to `@FocusState`.
///
/// Layout: 240×240 artwork on top, primary title + optional secondary line
/// below, all left-aligned within the tile width. Artwork loads via
/// `CachedAsyncImage` so scrolling away and back doesn't re-download.
struct MediaTile: View {
    let title: String
    let secondary: String?
    let artworkURL: URL?
    let placeholderSymbol: String
    let action: () -> Void

    /// Tile size — square artwork. Tuned for the focus engine: 240pt fits
    /// comfortably 6 across at 4K TV scale with ~48pt spacing.
    static let artworkSize: CGFloat = 240

    /// Focus scale factor. 1.10 = +24pt total growth at 240pt tile (12pt each
    /// side); 48pt inter-tile spacing leaves ~24pt clearance to the neighbor
    /// at peak focus. Tuned on hardware with the dim-others approach rejected
    /// (made the whole library look washed out) — the lift now carries the
    /// focus signal on its own, paired with the white glow shadow.
    private static let focusScale: CGFloat = 1.10

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        secondary: String? = nil,
        artworkURL: URL?,
        placeholderSymbol: String = "music.note",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.secondary = secondary
        self.artworkURL = artworkURL
        self.placeholderSymbol = placeholderSymbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                artwork
                    .frame(width: Self.artworkSize, height: Self.artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Self.artworkSize, alignment: .leading)

                if let secondary = secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: Self.artworkSize, alignment: .leading)
                } else {
                    // Reserve the secondary line's vertical space even when
                    // absent so neighboring tiles align on the same baseline.
                    Text(" ")
                        .font(.caption)
                        .frame(width: Self.artworkSize, alignment: .leading)
                }
            }
            .scaleEffect(isFocused ? Self.focusScale : 1.0)
            // Softer, smaller shadow — earlier 0.55/28 had a visible hard edge
            // where the glow got clipped against the ScrollView's top
            // boundary. The 1.10 scale carries most of the signal now; the
            // shadow is just a subtle lift cue, not the dominant indicator.
            .shadow(
                color: .white.opacity(isFocused ? 0.25 : 0),
                radius: isFocused ? 12 : 0,
                y: isFocused ? 4 : 0
            )
        }
        .buttonStyle(ChromelessButtonStyle())
        .focused($isFocused)
        .animation(
            reduceMotion ? .none : .easeInOut(duration: 0.15),
            value: isFocused
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(combinedAccessibility)
    }

    private var artwork: some View {
        CachedAsyncImage(url: artworkURL) {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
            Image(systemName: placeholderSymbol)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
        }
    }

    private var combinedAccessibility: String {
        if let secondary = secondary, !secondary.isEmpty {
            return "\(title), \(secondary)"
        }
        return title
    }
}


