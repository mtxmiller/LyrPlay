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
                TabView {
                    NavigationStack {
                        NowPlayingView(
                            nowPlaying: AudioManager.shared.getNowPlayingManager(),
                            coordinator: coordinator,
                            settings: settings,
                            audioPlayer: AudioManager.shared.audioPlayer,
                            onServerChanged: handleServerChanged,
                            onAudioFormatChanged: { handleAudioFormatChanged(coordinator: coordinator) }
                        )
                    }
                    .tabItem { Label("Now Playing", systemImage: "play.circle.fill") }

                    NavigationStack {
                        SearchView(
                            coordinator: coordinator,
                            settings: settings
                        )
                    }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }

                    NavigationStack {
                        LibraryView(
                            coordinator: coordinator,
                            nowPlaying: AudioManager.shared.getNowPlayingManager(),
                            settings: settings
                        )
                    }
                    .tabItem { Label("Library", systemImage: "music.note.house.fill") }
                }
                // tvOS HW play/pause is asymmetric (hardware-verified 2026-05-07):
                // - press while PLAYING → tvOS routes to MPRC pauseCommand (registered below)
                // - press while PAUSED → tvOS does NOT route to MPRC playCommand
                //   (system demotes the app from Now Playing dispatch when no audio is
                //   producing, even with .playback session active + UIBackgroundModes
                //   audio + nowPlayingInfo playbackRate=0). The press falls through the
                //   responder chain to this .onPlayPauseCommand instead.
                // Attached at TabView level so it catches the press regardless of which
                // tab/sub-view has focus. Both this and MPRC route to sendLockScreenCommand.
                .onPlayPauseCommand { coordinator.toggleLockScreenPlayPause() }
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

    // MARK: - Server change (Settings ▸ Change Server)

    /// Tears down the current SlimProtoCoordinator and rebuilds against the
    /// new host that ServerConnectView has already written to
    /// `settings.serverHost`. SettingsView clears the 3 recovery keys before
    /// invoking this closure (they point at the OLD server's playlist —
    /// CLAUDE.md rule #4 atomicity).
    ///
    /// Differs from `resetConfiguration()` in two ways:
    ///   1. Does NOT call `settings.resetConfiguration()` — that would zero
    ///      `serverHost`, but ServerConnectView just wrote the NEW host there.
    ///   2. Re-runs `startPlayerRegistration()` immediately so the user
    ///      doesn't need to drop back to the onboarding flow.
    // MARK: - Audio format change (Settings ▸ Audio Format)

    /// Audio format change requires a fresh HELO so the server learns the new
    /// capabilities. SlimProtoClient builds HELO from `settings.capabilitiesString`
    /// at connect time, so a quick disconnect+reconnect is enough — no need to
    /// tear down AudioManager.slimClient or clear recovery keys. Matches iOS
    /// SettingsView.swift:1733-1745 behavior.
    private func handleAudioFormatChanged(coordinator: SlimProtoCoordinator) {
        os_log(.info, log: logger, "🎵 Audio format changed — restarting SlimProto connection")
        Task {
            await coordinator.restartConnection()
        }
    }

    private func handleServerChanged() {
        os_log(.info, log: logger, "🔄 Server change committed — rebuilding coordinator against new host")
        coordinator?.disconnect()
        AudioManager.shared.slimClient = nil
        coordinator = nil
        unregisterRemoteCommands()
        startPlayerRegistration()
    }

    // MARK: - MPRemoteCommandCenter (per design D2 — register once, outlive sub-screens)
    //
    // D2 INVARIANT (98q.5): targets MUST be registered at ContentView scope, ABOVE TabView,
    // so Siri Remote hardware play/pause survives tab switching and sub-screen navigation.
    // Do NOT move this wiring into a tab content view or NowPlayingView — leaf-view
    // onAppear/onDisappear lifecycle silently breaks responsiveness when the user is on
    // another tab. See learning `tvos-mp-remotecommand-location` (8/10).
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

        let mpccLogger = logger
        center.playCommand.addTarget { _ in
            os_log(.debug, log: mpccLogger, "🎛️ MPRC playCommand fired")
            coordinator.sendLockScreenCommand("play")
            return .success
        }
        center.pauseCommand.addTarget { _ in
            os_log(.debug, log: mpccLogger, "🎛️ MPRC pauseCommand fired")
            coordinator.sendLockScreenCommand("pause")
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            os_log(.debug, log: mpccLogger, "🎛️ MPRC togglePlayPauseCommand fired (HW play/pause button)")
            let (_, playing) = coordinator.getCurrentInterpolatedTime()
            coordinator.sendLockScreenCommand(playing ? "pause" : "play")
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            os_log(.debug, log: mpccLogger, "🎛️ MPRC nextTrackCommand fired")
            coordinator.sendLockScreenCommand("next")
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            os_log(.debug, log: mpccLogger, "🎛️ MPRC previousTrackCommand fired")
            coordinator.sendLockScreenCommand("previous")
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            os_log(.debug, log: mpccLogger, "🎛️ MPRC changePlaybackPositionCommand fired")
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
