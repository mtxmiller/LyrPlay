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

/// One Settings row: title on the left, optional value, optional trailing
/// symbol. Every row in the Settings screens (links, switches, actions,
/// pickers) is built from this, so they all have the same height. The
/// system `Toggle` is not used: its own padding made switch rows taller
/// than the others.
struct SettingsRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var value: String? = nil
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Text(title)
                Spacer(minLength: 24)
                if let value {
                    Text(verbatim: value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                trailing()
            }
            .frame(minHeight: SettingsRowMetrics.minHeight)
        }
        .buttonStyle(.plain)
        .tvListRow()
    }
}

enum SettingsRowMetrics {
    /// Row content height. With the list's own row insets this gives the
    /// ~86 pt rows of the system tvOS Settings app.
    static let minHeight: CGFloat = 66
}

/// A row that opens another screen: value and a chevron on the right.
struct SettingsLinkRow: View {
    let title: LocalizedStringKey
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, value: value, action: action) {
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

/// An on/off setting, shown as "On"/"Off" like the system tvOS Settings.
/// Selecting the row flips it.
struct SettingsToggleRow: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title,
                    value: isOn ? String(localized: "On") : String(localized: "Off"),
                    action: { isOn.toggle() }) {
            EmptyView()
        }
        .accessibilityAddTraits(.isToggle)
    }
}
