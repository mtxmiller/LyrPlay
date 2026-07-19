import SwiftUI

/// Settings sub-screen for picking which shelves render on the Library tab.
///
/// Two sections:
/// - **Built-in** — the 13 `LibraryShelf` cases (Material `home-extra`
///   sorts). Each row carries an SF Symbol icon + a one-line description.
/// - **From plugins** — runtime-discovered `home-extra-3rdparty` shelves
///   (Spotty / TIDAL / Bandcamp / etc.). Each row carries the plugin's own
///   server-provided icon + title + subtitle. Only shown when the LMS
///   server reports registered plugin extras.
///
/// Pushed from SettingsView's "Library Shelves" row. Changes write straight
/// through to `SettingsManager.enabledLibraryShelves`, which `LibraryView`
/// observes via `.onChange` and refetches on each toggle.
///
/// Material stores its equivalent (`detailedHomeItems`) in browser
/// localStorage; there is no server-side pref to read, so tvOS keeps its
/// own per-device state.
struct LibraryShelvesPickerView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        TVList(.settings) {
            builtInSection
            if !settings.pluginExtraRegistry.isEmpty {
                pluginSection
            }
        }
        .navigationTitle("Library Shelves")
    }

    // MARK: - Built-in section

    private var builtInSection: some View {
        Section {
            ForEach(LibraryShelf.allCases) { shelf in
                ShelfPickerRow(
                    title: shelf.title,
                    subtitle: shelf.subtitle,
                    isOn: builtInBinding(for: shelf)
                ) {
                    Image(systemName: shelf.iconSystemName)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 48)
                }
                .tvListRow()
            }
        } header: {
            Text("Built-in Shelves").tvSectionHeader()
        } footer: {
            Text("Toggle which shelves appear on your Library tab. Order matches the on-screen order. Changes take effect immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Plugin section

    private var pluginSection: some View {
        Section {
            ForEach(settings.pluginExtraRegistry) { plugin in
                ShelfPickerRow(
                    title: plugin.title,
                    subtitle: plugin.subtitle ?? "Plugin shelf",
                    isOn: pluginBinding(for: plugin)
                ) {
                    CachedAsyncImage(url: plugin.iconURL(settings: settings)) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 48, height: 48)
                }
                .tvListRow()
            }
        } header: {
            Text("From Plugins").tvSectionHeader()
        } footer: {
            Text("Shelves contributed by LMS plugins installed on your server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private func builtInBinding(for shelf: LibraryShelf) -> Binding<Bool> {
        Binding(
            get: { settings.enabledLibraryShelves.contains(shelf.rawValue) },
            set: { isOn in
                if isOn {
                    settings.enabledLibraryShelves.insert(shelf.rawValue)
                } else {
                    settings.enabledLibraryShelves.remove(shelf.rawValue)
                }
                settings.saveSettings()
            }
        )
    }

    private func pluginBinding(for plugin: PluginExtraRegistration) -> Binding<Bool> {
        let key = plugin.shelfKey
        return Binding(
            get: { settings.enabledLibraryShelves.contains(key) },
            set: { isOn in
                if isOn {
                    settings.enabledLibraryShelves.insert(key)
                } else {
                    settings.enabledLibraryShelves.remove(key)
                }
                settings.saveSettings()
            }
        )
    }
}

/// One toggle row in the Library Shelves picker — leading icon slot,
/// title + subtitle, trailing toggle. Shared by the built-in section
/// (SF Symbol icon) and the plugin section (server artwork icon).
struct ShelfPickerRow<Icon: View>: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 16) {
                icon()
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
