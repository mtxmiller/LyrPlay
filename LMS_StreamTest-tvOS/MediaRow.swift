import SwiftUI

/// Generic list-row component shared by Queue, Favorites, Album lists, and Playlists.
///
/// Layout: 80×80 artwork + primary/secondary text column + flexible trailing slot
/// (current-track speaker indicator, duration label, year badge, etc).
///
/// Extracted from QueueView's QueueRow so all tvOS list views render identically and
/// AsyncImage / URL handling has one update site (see LMS_StreamTest-ppz, -7e4 follow-ups).
struct MediaRow<Trailing: View>: View {
    let primary: String
    let secondary: String?
    let artworkURL: URL?
    let isHighlighted: Bool
    let accentColor: Color
    @ViewBuilder let trailing: () -> Trailing

    init(
        primary: String,
        secondary: String? = nil,
        artworkURL: URL?,
        isHighlighted: Bool = false,
        accentColor: Color = .accentColor,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.primary = primary
        self.secondary = secondary
        self.artworkURL = artworkURL
        self.isHighlighted = isHighlighted
        self.accentColor = accentColor
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 24) {
            artwork
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(primary)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isHighlighted ? accentColor : Color.primary)

                if let secondary = secondary, !secondary.isEmpty {
                    Text(secondary)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            trailing()
                .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 8)
        // Default accessibility label so VoiceOver reads the full untruncated text.
        // Callers may override with their own .accessibilityLabel() (QueueView does this
        // to add "Now playing" + duration context).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(defaultAccessibilityLabel)
    }

    private var defaultAccessibilityLabel: String {
        if let secondary = secondary, !secondary.isEmpty {
            return "\(primary), \(secondary)"
        }
        return primary
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
    }
}

// Convenience initializer for rows with no trailing accessory.
extension MediaRow where Trailing == EmptyView {
    init(
        primary: String,
        secondary: String? = nil,
        artworkURL: URL?,
        isHighlighted: Bool = false,
        accentColor: Color = .accentColor
    ) {
        self.init(
            primary: primary,
            secondary: secondary,
            artworkURL: artworkURL,
            isHighlighted: isHighlighted,
            accentColor: accentColor
        ) {
            EmptyView()
        }
    }
}
