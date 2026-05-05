import SwiftUI
import Combine
import os.log

struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var connectionStatus: String = "Connecting…"
    @State private var isConnected: Bool = false

    private let logger = OSLog(subsystem: "com.lmsstream", category: "tvOSContentView")
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .imageScale(.large)
                .font(.system(size: 96))
                .foregroundStyle(isConnected ? .green : .yellow)
            Text(connectionStatus)
                .font(.largeTitle)
            Text(verbatim: "\(settings.serverHost):\(settings.serverWebPort)")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Player UI lands in 98q.5.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 16)

            Button(role: .destructive) {
                AudioManager.shared.slimClient?.disconnect()
                AudioManager.shared.slimClient = nil
                settings.resetConfiguration()
            } label: {
                Text("Reset configuration")
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
            }
            .padding(.top, 32)
        }
        .padding()
        .onAppear { startPlayerRegistration() }
        .onReceive(pollTimer) { _ in refreshConnectionStatus() }
    }

    private func startPlayerRegistration() {
        let audioMgr = AudioManager.shared
        let coordinator: SlimProtoCoordinator
        if let existing = audioMgr.slimClient {
            os_log(.info, log: logger, "♻️ Reusing existing SlimProtoCoordinator")
            coordinator = existing
        } else {
            os_log(.info, log: logger, "🆕 Creating SlimProtoCoordinator for tvOS")
            coordinator = SlimProtoCoordinator(audioManager: audioMgr)
        }

        audioMgr.setSlimClient(coordinator)
        coordinator.updateServerSettings(
            host: settings.activeServerHost,
            port: UInt16(settings.activeServerSlimProtoPort)
        )

        if !coordinator.isConnected {
            os_log(.info, log: logger, "📡 Initiating SlimProto connection from tvOS")
            coordinator.connect()
        } else {
            os_log(.info, log: logger, "✅ Coordinator already connected")
        }

        refreshConnectionStatus()
    }

    private func refreshConnectionStatus() {
        guard let coordinator = AudioManager.shared.slimClient else {
            connectionStatus = "Not started"
            isConnected = false
            return
        }
        let state = coordinator.connectionState
        connectionStatus = state
        isConnected = coordinator.isConnected
    }
}

#Preview {
    ContentView()
}
