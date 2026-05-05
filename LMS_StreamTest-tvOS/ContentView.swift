import SwiftUI
import Combine
import MediaPlayer
import os.log

struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var coordinator: SlimProtoCoordinator?
    @State private var connectionStatus: String = "Connecting…"
    @State private var isConnected: Bool = false
    @State private var remoteCommandsRegistered: Bool = false

    private let logger = OSLog(subsystem: "com.lmsstream", category: "tvOSContentView")
    private let pollTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let coordinator, isConnected {
                NavigationStack {
                    NowPlayingView(
                        nowPlaying: AudioManager.shared.getNowPlayingManager(),
                        coordinator: coordinator,
                        settings: settings
                    )
                }
            } else {
                connectingView
            }
        }
        .onAppear { startPlayerRegistration() }
        .onReceive(pollTimer) { _ in refreshConnectionStatus() }
    }

    // MARK: - Connecting state

    private var connectingView: some View {
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

            Button(role: .destructive) {
                resetConfiguration()
            } label: {
                Text("Reset configuration")
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
            }
            .padding(.top, 32)
        }
        .padding()
    }

    // MARK: - Player registration

    private func startPlayerRegistration() {
        let audioMgr = AudioManager.shared
        let resolved: SlimProtoCoordinator
        if let existing = audioMgr.slimClient {
            os_log(.info, log: logger, "♻️ Reusing existing SlimProtoCoordinator")
            resolved = existing
        } else {
            os_log(.info, log: logger, "🆕 Creating SlimProtoCoordinator for tvOS")
            resolved = SlimProtoCoordinator(audioManager: audioMgr)
        }

        audioMgr.setSlimClient(resolved)
        resolved.updateServerSettings(
            host: settings.activeServerHost,
            port: UInt16(settings.activeServerSlimProtoPort)
        )

        if !resolved.isConnected {
            os_log(.info, log: logger, "📡 Initiating SlimProto connection from tvOS")
            resolved.connect()
        } else {
            os_log(.info, log: logger, "✅ Coordinator already connected")
        }

        coordinator = resolved
        refreshConnectionStatus()
    }

    private func refreshConnectionStatus() {
        guard let coordinator else {
            connectionStatus = "Not started"
            isConnected = false
            return
        }
        connectionStatus = coordinator.connectionState
        let nowConnected = coordinator.isConnected
        isConnected = nowConnected

        if nowConnected && !remoteCommandsRegistered {
            registerRemoteCommands(coordinator: coordinator)
        }
    }

    // MARK: - Reset

    private func resetConfiguration() {
        coordinator?.disconnect()
        AudioManager.shared.slimClient = nil
        coordinator = nil
        unregisterRemoteCommands()
        settings.resetConfiguration()
    }

    // MARK: - MPRemoteCommandCenter (per design D2 — register once, outlive sub-screens)

    private func registerRemoteCommands(coordinator: SlimProtoCoordinator) {
        let center = MPRemoteCommandCenter.shared()

        // Idempotent: clear any prior targets before registering
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { _ in
            coordinator.sendLockScreenCommand("play")
            return .success
        }
        center.pauseCommand.addTarget { _ in
            coordinator.sendLockScreenCommand("pause")
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            let (_, playing) = coordinator.getCurrentInterpolatedTime()
            coordinator.sendLockScreenCommand(playing ? "pause" : "play")
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            coordinator.sendLockScreenCommand("next")
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            coordinator.sendLockScreenCommand("previous")
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            coordinator.seek(toSeconds: positionEvent.positionTime)
            return .success
        }

        remoteCommandsRegistered = true
        os_log(.info, log: logger, "🎛️ Registered MPRemoteCommandCenter targets for tvOS")
    }

    private func unregisterRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        remoteCommandsRegistered = false
    }
}

#Preview {
    ContentView()
}
