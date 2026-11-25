import SwiftUI
import StoreKit
import os.log

/// tvOS Settings. Every screen uses `SettingsPage` (symbol + status on the
/// left, list on the right, like Apple's Settings app). The root screen is a
/// short list; each row opens its own screen:
///   - Server: opens ServerConnectView in change-server mode (`onComplete`, E6).
///   - Player Name: PlayerNameView saves the name and renames the player in LMS.
///   - Keep Screen Awake: toggle.
///   - Audio: AudioSettingsView (format, fixed output level, sample rate,
///     signal path on the left).
///   - Library Shelves: LibraryShelvesPickerView.
///   - About: version, build, player MAC, Restore Purchases.
///
/// Row pattern: `Button + .buttonStyle(.plain) + .tvListRow()` and manual
/// navigation (`NavigationLink` gives tvOS Lists a wide white-pill focus halo
/// that hides the row text).
///
/// `onServerChanged` is called when the user commits a new server from
/// Change Server. ContentView reconnects the existing coordinator (E1).
struct SettingsView: View {
    @ObservedObject var settings: SettingsManager
    var onServerChanged: () -> Void
    /// Called when the user picks a new audio format. ContentView restarts
    /// the SlimProto connection so the server gets a fresh HELO with the new
    /// capabilities (same as iOS).
    var onAudioFormatChanged: () -> Void

    private enum Route: Hashable {
        case server, playerName, audio, shelves, about
    }

    @State private var path: [Route] = []

    private let logger = OSLog(subsystem: "com.lmsstream", category: "tvOSSettings")

    var body: some View {
        TVScreen {
            NavigationStack(path: $path) {
                SettingsPage(
                    systemImage: "gearshape",
                    title: "Settings",
                    details: rootDetails
                ) {
                    Section {
                        SettingsLinkRow(title: "Server", value: settings.serverHost.isEmpty ? "—" : settings.serverHost) {
                            path.append(.server)
                        }
                        SettingsLinkRow(title: "Player Name", value: settings.effectivePlayerName) {
                            path.append(.playerName)
                        }
                        SettingsToggleRow(title: "Keep Screen Awake", isOn: $settings.keepScreenAwake)
                            .onChange(of: settings.keepScreenAwake) { _, _ in
                                settings.saveSettings()
                                AudioManager.shared.getNowPlayingManager().applyIdleTimerSetting()
                            }
                    }
                    Section {
                        SettingsLinkRow(title: "Audio", value: settings.audioFormat.displayName) {
                            path.append(.audio)
                        }
                        SettingsLinkRow(title: "Library Shelves", value: shelvesValue) {
                            path.append(.shelves)
                        }
                        SettingsLinkRow(title: "About") {
                            path.append(.about)
                        }
                    }
                }
                // No navigationTitle: the tab bar already says "Settings",
                // and the left panel names each screen.
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
                .onChange(of: settings.audioFormat) { _, _ in
                    os_log(.info, log: logger, "Audio format changed — saving + restarting connection")
                    settings.saveSettings()
                    onAudioFormatChanged()
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .server:
            ServerConnectView(onComplete: {
                os_log(.info, log: logger, "Server change committed — invoking onServerChanged")
                SettingsServerChange.clearRecoveryKeys()
                onServerChanged()
            })
        case .playerName:
            PlayerNameView(settings: settings)
        case .audio:
            AudioSettingsView(settings: settings)
        case .shelves:
            SettingsPage(systemImage: "rectangle.stack", title: "Library Shelves",
                         details: [String(localized: "Choose what the Library tab shows.")]) {
                LibraryShelvesPickerView(settings: settings).sections
            }
        case .about:
            AboutSettingsView(settings: settings)
        }
    }

    private var rootDetails: [String] {
        var lines = [settings.effectivePlayerName]
        if !settings.serverHost.isEmpty {
            lines.append(String(localized: "Connected to \(settings.serverHost)"))
        }
        if !settings.serverUsername.isEmpty {
            lines.append(String(localized: "Signed in as \(settings.serverUsername)"))
        }
        return lines
    }

    private var shelvesValue: String {
        String(localized: "\(settings.enabledLibraryShelves.count + (settings.showBrowseShelf ? 1 : 0)) on")
    }
}

// MARK: - Player name

/// Edits the player name. Saving stores it and renames the player in LMS
/// right away (`<player> name <new>`), so no reconnect is needed. Before,
/// the name was only stored when another setting saved, and LMS only saw it
/// at the next connect.
private struct PlayerNameView: View {
    @ObservedObject var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @FocusState private var fieldFocused: Bool

    private let logger = OSLog(subsystem: "com.lmsstream", category: "tvOSSettings")

    var body: some View {
        SettingsPage(systemImage: "tv", title: "Player Name",
                     details: [String(localized: "The name LMS and other apps show for this Apple TV.")]) {
            Section {
                TextField(settings.effectivePlayerName, text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($fieldFocused)
                    .onSubmit(save)
                    .tvListRow()
                SettingsRow(title: "Save", action: save) { EmptyView() }
                .disabled(trimmed.isEmpty || trimmed == settings.effectivePlayerName)
            }
        }
        .onAppear { name = settings.playerName }
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let newName = trimmed
        guard !newName.isEmpty else { return }
        settings.playerName = newName
        settings.saveSettings()
        if let coordinator = AudioManager.shared.slimClient {
            let request: [String: Any] = [
                "id": 1,
                "method": "slim.request",
                "params": [settings.playerMACAddress, ["name", newName]]
            ]
            coordinator.sendJSONRPCCommandDirect(request) { _ in }
        }
        os_log(.info, log: logger, "Player renamed to %{public}s", newName)
        dismiss()
    }
}

// MARK: - Audio

private struct AudioSettingsView: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject private var audioPlayer = AudioManager.shared.audioPlayer
    @State private var showFormatPicker = false

    var body: some View {
        SettingsPage(systemImage: "waveform", title: "Audio", details: signalPathLines) {
            Section {
                SettingsLinkRow(title: "Format", value: settings.audioFormat.displayName) {
                    showFormatPicker = true
                }
                SettingsToggleRow(title: "Fix Output Level at 100%", isOn: $settings.fixOutputAt100Percent)
                    .onChange(of: settings.fixOutputAt100Percent) { _, newValue in
                        settings.saveSettings()
                        if newValue {
                            AudioManager.shared.slimClient?.applyFixedOutputPolicy()
                        } else {
                            AudioManager.shared.slimClient?.restoreSoftwareVolumeControl()
                        }
                    }
                SettingsToggleRow(title: "Match Output Sample Rate", isOn: $settings.matchOutputSampleRate)
                    .onChange(of: settings.matchOutputSampleRate) { _, _ in
                        settings.saveSettings()
                    }
            } footer: {
                Text("Match Output Sample Rate sends each track to the TV or receiver at its own rate (44.1 to 192 kHz). The sound may stop for a moment at each change. Off keeps 48 kHz.")
            }
        }
        .navigationDestination(isPresented: $showFormatPicker) {
            FormatPickerView(selection: $settings.audioFormat)
        }
        .onAppear { audioPlayer.updateOutputDeviceInfo() }
    }

    /// What plays and what goes out over HDMI, like the iPhone's Signal Path
    /// (GH #150). Shown on the left: it is status, not a setting.
    private var signalPathLines: [String] {
        guard let stream = audioPlayer.currentStreamInfo, let output = audioPlayer.currentOutputInfo else {
            return [String(localized: "Signal Path: nothing playing")]
        }
        let matches = abs(stream.sampleRate - output.outputSampleRate) < 100 && output.mixSampleRate == nil
        let source = stream.isSavedCopy ? String(localized: "Saved copy") + " · " : ""
        var lines = [
            matches ? String(localized: "Signal Path: native rate") : String(localized: "Signal Path: resampled"),
            "\(source)\(stream.format) \(AudioPlayer.formatSampleRateKHz(stream.sampleRate)) kHz · \(stream.bitDepth)-bit",
            "→ \(output.deviceName) \(AudioPlayer.formatSampleRateKHz(output.outputSampleRate)) kHz"
        ]
        if let mix = output.mixSampleRate {
            lines.append(String(localized: "Mixed at \(AudioPlayer.formatSampleRateKHz(mix)) kHz"))
        }
        return lines
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    @ObservedObject var settings: SettingsManager

    @State private var isRestoringPurchases = false
    @State private var showRestoreAlert = false
    @State private var restoreAlertTitle = ""
    @State private var restoreAlertMessage = ""

    private let logger = OSLog(subsystem: "com.lmsstream", category: "tvOSSettings")

    var body: some View {
        let info = SettingsServerChange.aboutInfo(
            serverHost: settings.serverHost,
            playerMAC: settings.playerMACAddress
        )
        SettingsPage(systemImage: "info.circle", title: "About", details: [
            String(localized: "LyrPlay \(info.version.isEmpty ? "—" : info.version) (\(info.build.isEmpty ? "—" : info.build))"),
            String(localized: "Server: \(info.host.isEmpty ? "—" : info.host)"),
            String(localized: "Player MAC: \(info.playerMAC.isEmpty ? "—" : info.playerMAC)")
        ]) {
            // App Review Guideline 3.1.1: iOS and tvOS share one App Store
            // record (universal purchase), so the iOS icon-pack IAP is listed
            // on the tvOS product page and tvOS must offer Restore Purchases.
            // `AppStore.sync()` is StoreKit 2's restore.
            Section {
                SettingsRow(title: isRestoringPurchases ? "Restoring…" : "Restore Purchases",
                            action: restorePurchases) {
                    if isRestoringPurchases { ProgressView() }
                }
                .disabled(isRestoringPurchases)
            } footer: {
                Text("Purchases made in LyrPlay on iPhone or iPad are shared with this Apple TV automatically.")
            }
        }
        .alert(restoreAlertTitle, isPresented: $showRestoreAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(restoreAlertMessage)
        }
    }

    private func restorePurchases() {
        guard !isRestoringPurchases else { return }
        isRestoringPurchases = true
        Task {
            defer { isRestoringPurchases = false }
            do {
                try await AppStore.sync()
                os_log(.info, log: logger, "Restore purchases: sync complete")
                restoreAlertTitle = String(localized: "Restore Complete")
                restoreAlertMessage = String(localized: "Your previous purchases have been restored to this Apple TV.")
                showRestoreAlert = true
            } catch StoreKitError.userCancelled {
                os_log(.info, log: logger, "Restore purchases: user cancelled")
            } catch {
                os_log(.error, log: logger, "Restore purchases failed: %{public}s", error.localizedDescription)
                restoreAlertTitle = String(localized: "Restore Failed")
                restoreAlertMessage = error.localizedDescription
                showRestoreAlert = true
            }
        }
    }
}

/// Detail screen for the Audio Format picker. Pushed via .navigationDestination
/// so each format's full `displayName` is readable on its own row.
private struct FormatPickerView: View {
    @Binding var selection: SettingsManager.AudioFormat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsPage(systemImage: "waveform", title: "Format") {
            ForEach(SettingsManager.AudioFormat.allCases, id: \.self) { fmt in
                Button {
                    selection = fmt
                    dismiss()
                } label: {
                    HStack {
                        Text(fmt.displayName)
                        Spacer()
                        if fmt == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                    .frame(minHeight: SettingsRowMetrics.minHeight)
                }
                .buttonStyle(.plain)
                .tvListRow()
            }
        }
    }
}

#Preview {
    SettingsView(
        settings: SettingsManager.shared,
        onServerChanged: { },
        onAudioFormatChanged: { }
    )
}
