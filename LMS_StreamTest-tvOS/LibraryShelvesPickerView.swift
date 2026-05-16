import SwiftUI

/// Settings sub-screen for picking which `home-extra` shelves render on the
/// Library tab. Mirrors Material's `detailedHomeItems` user pref UX, but
/// stored locally per-device (Material stores its equivalent in browser
/// localStorage; there is no server-side pref to read).
///
/// Pushed from SettingsView's "Library Shelves" row via `.navigationDestination`.
/// Changes write straight through to `SettingsManager.enabledLibraryShelves`,
/// which `LibraryView` observes via `.onChange` and refetches on each toggle.
struct LibraryShelvesPickerView: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        TVList(.settings) {
            Section {
                ForEach(LibraryShelf.allCases) { shelf in
                    Toggle(shelf.title, isOn: binding(for: shelf))
                        .tvListRow()
                }
            } header: {
                Text("Library Shelves")
            } footer: {
                Text("Toggle which shelves appear on your Library tab. Order matches the on-screen order. Changes take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Library Shelves")
    }

    private func binding(for shelf: LibraryShelf) -> Binding<Bool> {
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
}
