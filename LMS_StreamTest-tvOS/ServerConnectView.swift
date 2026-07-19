import SwiftUI

struct ServerConnectView: View {
    /// Called on successful host commit when the user is changing servers
    /// from inside the app (Settings ▸ Change Server). When nil, the view
    /// behaves as the fresh-install / Reset path: writes the host and calls
    /// `settings.markAsConfigured()` so RootView swaps to ContentView.
    /// When non-nil, writes the host and calls `onComplete()` instead — the
    /// caller is responsible for tearing down + rebuilding the existing
    /// SlimProtoCoordinator. (E1 + E6 from /plan-eng-review 2026-05-07.)
    var onComplete: (() -> Void)? = nil

    @StateObject private var discovery = ServerDiscoveryManager()
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case manualEntry
        case retry
    }

    var body: some View {
        VStack(spacing: 40) {
            Text("Connect to your LMS server")
                .font(.largeTitle)
                .padding(.top, 60)

            content

            Spacer()
        }
        .frame(maxWidth: 900)
        .padding(.horizontal, 80)
        .onAppear { discovery.startDiscovery() }
        .defaultFocus($focusedField, .manualEntry)
    }

    @ViewBuilder
    private var content: some View {
        if discovery.isDiscovering && discovery.discoveredServers.isEmpty {
            discoveringSection
        } else if discovery.discoveredServers.isEmpty {
            emptySection
        } else {
            populatedSection
        }
    }

    private var discoveringSection: some View {
        VStack(spacing: 32) {
            HStack(spacing: 16) {
                ProgressView()
                Text("Searching for servers on your network…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 24)

            manualEntryLink
                .buttonStyle(.bordered)
        }
    }

    private var emptySection: some View {
        VStack(spacing: 32) {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("No servers found on your network.")
                    .font(.title3)
                Text("If your server is on a different network or your router blocks broadcasts, enter the address manually.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 24)

            HStack(spacing: 24) {
                Button {
                    discovery.startDiscovery()
                } label: {
                    Label("Search again", systemImage: "arrow.clockwise")
                        .padding(.horizontal, 16)
                }
                .focused($focusedField, equals: .retry)

                manualEntryLink
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var populatedSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Discovered on your network")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                ForEach(discovery.discoveredServers) { server in
                    Button {
                        applyDiscoveredServer(server)
                    } label: {
                        HStack(spacing: 24) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 28))
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                    .font(.title3)
                                Text(verbatim: "\(server.host):\(server.port)")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel("\(server.name), \(server.host) port \(server.port)")
                }
            }

            HStack(spacing: 24) {
                Text(discovery.isDiscovering
                     ? "Searching for more…"
                     : "Found \(discovery.discoveredServers.count) server\(discovery.discoveredServers.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    discovery.startDiscovery()
                } label: {
                    Label("Search again", systemImage: "arrow.clockwise")
                }
                .focused($focusedField, equals: .retry)
            }
            .padding(.top, 8)

            Divider()
                .padding(.vertical, 16)

            HStack {
                Spacer()
                manualEntryLink
                    .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private var manualEntryLink: some View {
        NavigationLink {
            ManualServerEntryView(onComplete: onComplete)
        } label: {
            Label("Enter server manually", systemImage: "keyboard")
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        }
        .focused($focusedField, equals: .manualEntry)
        .accessibilityLabel("Enter server address manually")
    }

    private func applyDiscoveredServer(_ server: DiscoveredServer) {
        let settings = SettingsManager.shared
        settings.serverHost = server.host
        settings.serverWebPort = server.port
        settings.serverSlimProtoPort = 3483
        settings.saveSettings()

        if let onComplete {
            onComplete()
        } else {
            settings.markAsConfigured()
        }
    }
}

#Preview {
    NavigationStack {
        ServerConnectView()
    }
}
