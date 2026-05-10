import SwiftUI
import os.log

/// tvOS Settings — single-screen List wrapped in a NavigationStack so
/// "Change Server" and "Audio Format" can push detail screens without
/// leaving the cover.
///
/// Scope per design doc + /plan-eng-review (LMS_StreamTest-53n):
///   - Server: shows current host, button pushes ServerConnectView
///     (in change-server mode via `onComplete` parameter — E6).
///   - Player Name: inline TextField bound to `settings.playerName`. Re-HELO
///     happens on next reconnect (deferred, not urgent).
///   - Audio Format: Button pushes a custom FormatPickerView so the full
///     format displayNames are readable. (`.pickerStyle(.navigationLink)`
///     was tried but pushed a transparent side-sheet that let NowPlayingView
///     bleed through.)
///   - About: 4 non-focusable rows — version, build, host, player MAC.
///
/// Row pattern: `Button + .buttonStyle(.plain) + .listRowBackground(Color.clear)`
/// matches the project convention (SearchView / AlbumListView / FavoritesView).
/// `NavigationLink` gives tvOS Lists a wide white-pill focus halo that
/// obscures the row text — Buttons + manual navigation via `.navigationDestination`
/// avoid that.
///
/// `onServerChanged` is called when the user successfully commits a NEW host
/// from inside Change Server. Caller (NowPlayingView → ContentView) is
/// responsible for clearing recovery keys + tearing down + rebuilding the
/// SlimProtoCoordinator (E1).
struct SettingsView: View {
    @ObservedObject var settings: SettingsManager
    var onServerChanged: () -> Void
    /// Called when the user picks a new audio format. Caller (ContentView)
    /// re-runs the SlimProto connection so the server gets a fresh HELO with
    /// the new capabilities string. Matches the iOS pattern at
    /// SettingsView.swift:1733-1745. Without this, the server keeps using
    /// the OLD capabilities until the user restarts the app.
    var onAudioFormatChanged: () -> Void

    @State private var showServerChange = false
    @State private var showFormatPicker = false

    private let logger = OSLog(subsystem: "com.lmsstream", category: "tvOSSettings")

    var body: some View {
        NavigationStack {
            List {
                serverSection
                playerSection
                audioSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $showServerChange) {
                ServerConnectView(onComplete: {
                    os_log(.info, log: logger, "Server change committed — invoking onServerChanged")
                    SettingsServerChange.clearRecoveryKeys()
                    onServerChanged()
                })
            }
            .navigationDestination(isPresented: $showFormatPicker) {
                FormatPickerView(selection: $settings.audioFormat)
            }
            .onChange(of: settings.audioFormat) { _, _ in
                os_log(.info, log: logger, "Audio format changed — saving + restarting connection")
                settings.saveSettings()
                onAudioFormatChanged()
            }
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section("Server") {
            row(label: "Current host", value: settings.serverHost.isEmpty ? "—" : settings.serverHost)

            Button {
                showServerChange = true
            } label: {
                Label("Change Server", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Player

    private var playerSection: some View {
        Section("Player") {
            TextField("Player name", text: $settings.playerName)
                .accessibilityLabel("Player name")
                .listRowBackground(Color.clear)

            Toggle("Keep screen awake during playback", isOn: $settings.keepScreenAwake)
                .listRowBackground(Color.clear)
                .onChange(of: settings.keepScreenAwake) { _, _ in
                    settings.saveSettings()
                    AudioManager.shared.getNowPlayingManager().applyIdleTimerSetting()
                }
        }
    }

    // MARK: - Audio Format

    private var audioSection: some View {
        Section("Audio Format") {
            Button {
                showFormatPicker = true
            } label: {
                HStack {
                    Text("Format")
                    Spacer()
                    Text(settings.audioFormat.displayName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        let info = SettingsServerChange.aboutInfo(
            serverHost: settings.serverHost,
            playerMAC: settings.playerMACAddress
        )
        return Section("About") {
            row(label: "Version", value: info.version.isEmpty ? "—" : info.version)
            row(label: "Build", value: info.build.isEmpty ? "—" : info.build)
            row(label: "Server", value: info.host.isEmpty ? "—" : info.host)
            row(label: "Player MAC", value: info.playerMAC.isEmpty ? "—" : info.playerMAC)
        }
    }

    // MARK: - Helpers

    /// Non-focusable label/value row. tvOS focus engine skips these so the
    /// user can't land on About info — it's read-only by design.
    @ViewBuilder
    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .focusable(false)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// Detail screen for the Audio Format picker. Pushed via .navigationDestination
/// so each format's full `displayName` is readable on its own row.
private struct FormatPickerView: View {
    @Binding var selection: SettingsManager.AudioFormat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
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
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Audio Format")
    }
}

#Preview {
    SettingsView(
        settings: SettingsManager.shared,
        onServerChanged: { },
        onAudioFormatChanged: { }
    )
}
