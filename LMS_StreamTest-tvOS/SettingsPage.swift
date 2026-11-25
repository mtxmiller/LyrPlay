import SwiftUI

/// Layout for every tvOS Settings screen, like Apple's own Settings app: a
/// large symbol with a title and short status text on the left, the list on
/// the right. The list only takes the right half of the screen, so rows and
/// their focus highlight are no longer full-width bars, and status text
/// (server, version, signal path) lives on the left instead of in rows that
/// can be focused but do nothing.
struct SettingsPage<Content: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    /// Lines under the title. Plain strings: callers pass values (host,
    /// version) or already-localized text.
    var details: [String] = []
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 80) {
            VStack(spacing: 28) {
                Image(systemName: systemImage)
                    .font(.system(size: 200, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(height: 260)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                VStack(spacing: 8) {
                    ForEach(details, id: \.self) { line in
                        Text(verbatim: line)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(width: 620)
            .accessibilityElement(children: .combine)

            TVList(.settings) {
                content()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 60)
    }
}

/// A row that opens another screen: title on the left, current value and a
/// chevron on the right.
struct SettingsLinkRow: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 44)
                }
                Text(title)
                Spacer(minLength: 24)
                if let value {
                    Text(verbatim: value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .tvListRow()
    }
}
