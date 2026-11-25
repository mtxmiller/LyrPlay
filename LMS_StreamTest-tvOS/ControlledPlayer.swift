import SwiftUI
import Combine
import os.log

/// The LMS player the tvOS app controls (bd 9dtq, GH #103).
///
/// The Apple TV stays a player: its SlimProto connection, audio, system Now
/// Playing info and recovery are untouched. Picking another player only
/// changes where Now Playing reads from and where commands, Browse and Queue
/// send their player id (`targetID`). Status of another player comes from
/// polling JSON-RPC `status`; it never goes into NowPlayingManager.
@MainActor
final class ControlledPlayer: ObservableObject {
    static let shared = ControlledPlayer()

    /// nil = this Apple TV.
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedName: String = ""
    /// Picker rows, refreshed by `refreshPlayers()`.
    @Published private(set) var choices: [PlayerChoice] = []
    @Published private(set) var isLoadingPlayers = false
    /// Last status of the selected other player.
    @Published private(set) var status: PlayerStatus?
    @Published private(set) var artwork: UIImage?
    /// True when the last status poll failed (player gone or server down).
    @Published private(set) var statusFailed = false

    private var statusAt: Date = .distantPast
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var artworkKey: String?
    private var commandGeneration = 0

    private let settings = SettingsManager.shared
    private let logger = OSLog(subsystem: "com.lmsstream", category: "ControlledPlayer")
    private static let selectedKey = "tvos_controlled_player_id"
    private static let selectedNameKey = "tvos_controlled_player_name"

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.selectedKey)
        if let saved, !saved.isEmpty, saved.lowercased() != settings.playerMACAddress.lowercased() {
            selectedID = saved
            selectedName = UserDefaults.standard.string(forKey: Self.selectedNameKey) ?? saved
            startPolling()
        }
    }

    var isRemote: Bool { selectedID != nil }

    /// The player id every command, Browse and Queue request uses.
    var targetID: String { selectedID ?? settings.playerMACAddress }

    /// Name shown on the "Playing on" button.
    var displayName: String {
        isRemote ? selectedName : String(localized: "This Apple TV")
    }

    private var coordinator: SlimProtoCoordinator? { AudioManager.shared.slimClient }

    // MARK: - Selection

    func select(_ choice: PlayerChoice) {
        if choice.isThisDevice {
            selectThisDevice()
            return
        }
        // A player that is off turns on when picked (design screen 2).
        if !choice.isPoweredOn {
            send(["power", 1], to: choice.id)
        }
        os_log(.info, log: logger, "Controlling %{public}s (%{public}s)", choice.name, choice.id)
        selectedID = choice.id
        selectedName = choice.name
        status = nil
        artwork = nil
        artworkKey = nil
        statusFailed = false
        UserDefaults.standard.set(choice.id, forKey: Self.selectedKey)
        UserDefaults.standard.set(choice.name, forKey: Self.selectedNameKey)
        startPolling()
    }

    func selectThisDevice() {
        guard isRemote else { return }
        os_log(.info, log: logger, "Controlling this Apple TV")
        stopPolling()
        selectedID = nil
        selectedName = ""
        status = nil
        artwork = nil
        artworkKey = nil
        statusFailed = false
        UserDefaults.standard.removeObject(forKey: Self.selectedKey)
        UserDefaults.standard.removeObject(forKey: Self.selectedNameKey)
        AudioManager.shared.getNowPlayingManager().applyIdleTimerSetting()
    }

    // MARK: - Player list

    func refreshPlayers() {
        guard let coordinator else { return }
        isLoadingPlayers = choices.isEmpty
        let playersRequest = Self.request(["", ["players", 0, 100]])
        coordinator.sendJSONRPCCommandDirect(playersRequest) { [weak self] playersResponse in
            let players = PlayerList.players(from: playersResponse["result"] as? [String: Any] ?? [:])
            let groupsRequest = Self.request(["", ["syncgroups", "?"]])
            coordinator.sendJSONRPCCommandDirect(groupsRequest) { groupsResponse in
                let groups = PlayerList.syncGroups(from: groupsResponse["result"] as? [String: Any] ?? [:])
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isLoadingPlayers = false
                    // Keep the last list when the server didn't answer.
                    guard !players.isEmpty else { return }
                    self.choices = PlayerList.choices(players: players, groups: groups,
                                                      thisDeviceID: self.settings.playerMACAddress)
                    self.syncSelectedName()
                }
            }
        }
    }

    /// Follows renames and group changes of the selected player.
    private func syncSelectedName() {
        guard let selectedID,
              let choice = choices.first(where: { c in c.members.contains { $0.id.lowercased() == selectedID.lowercased() } })
        else { return }
        if choice.isThisDevice {
            selectThisDevice()
        } else if choice.name != selectedName {
            selectedName = choice.name
            UserDefaults.standard.set(choice.name, forKey: Self.selectedNameKey)
        }
    }

    // MARK: - Status polling

    private func startPolling() {
        stopPolling()
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInFlight = false
    }

    private func poll() {
        guard let selectedID, let coordinator, !pollInFlight else { return }
        pollInFlight = true
        let generation = commandGeneration
        let request = Self.request([selectedID, ["status", "-", 1, "tags:adlcKN"]])
        coordinator.sendJSONRPCCommandDirect(request, timeout: 4) { [weak self] response in
            let result = response["result"] as? [String: Any]
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pollInFlight = false
                guard self.selectedID == selectedID else { return }
                guard let result, !result.isEmpty else {
                    self.statusFailed = true
                    return
                }
                // A status that left before a command was sent can show the
                // old state; skip it, the next poll has the new one.
                guard generation == self.commandGeneration else { return }
                self.statusFailed = false
                self.apply(PlayerStatus.parse(result))
            }
        }
    }

    private func apply(_ new: PlayerStatus) {
        status = new
        statusAt = Date()
        loadArtworkIfNeeded(for: new)
        // Keep Screen Awake follows the controlled player.
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && new.isPlaying
    }

    /// Elapsed time, counted forward between polls while playing.
    var elapsed: Double {
        guard let status else { return 0 }
        guard status.isPlaying else { return status.time }
        let t = status.time + Date().timeIntervalSince(statusAt)
        return status.duration > 0 ? min(t, status.duration) : t
    }

    // MARK: - Artwork

    private func loadArtworkIfNeeded(for status: PlayerStatus) {
        let url = Self.artworkURL(for: status, settings: settings)
        let key = url?.absoluteString
        guard key != artworkKey else { return }
        artworkKey = key
        guard let url else {
            artwork = nil
            return
        }
        Task { [weak self] in
            let request = CachedAsyncImage<EmptyView>.request(for: url)
            let session = CachedAsyncImage<EmptyView>.session(for: url)
            guard let (data, _) = try? await session.data(for: request),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                guard let self, self.artworkKey == key else { return }
                self.artwork = image
            }
        }
    }

    /// Large cover for Now Playing: the server's cover for library tracks,
    /// the stream's own artwork for radio and plugins.
    static func artworkURL(for status: PlayerStatus, settings: SettingsManager) -> URL? {
        if let art = status.artworkURL, !art.isEmpty {
            return LMSArtworkURL.favoriteIcon(art, settings: settings)
        }
        guard let cover = status.coverID, !cover.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = settings.activeServerHost
        components.port = settings.activeServerWebPort
        components.path = "/music/\(cover)/cover_600x600_o.jpg"
        return components.url
    }

    // MARK: - Commands (selected other player only)

    func togglePlayPause() {
        guard let status else { return }
        setPlaying(!status.isPlaying)
    }

    func setPlaying(_ playing: Bool) {
        send(playing ? ["play"] : ["pause", 1])
        status?.mode = playing ? "play" : "pause"
        statusAt = Date()
    }

    func next() { send(["playlist", "index", "+1"]) }
    func previous() { send(["playlist", "index", "-1"]) }

    func seek(to seconds: Double) {
        send(["time", Int(seconds.rounded())])
        status?.time = seconds
        statusAt = Date()
    }

    func changeVolume(by delta: Int) {
        guard let status else { return }
        let current = max(0, status.volume)
        let target = min(100, max(0, current + delta))
        send(["mixer", "volume", target])
        self.status?.volume = target
    }

    func toggleShuffle() {
        guard let status else { return }
        let mode = PlaylistModeCycle.nextShuffle(status.shuffleMode)
        send(["playlist", "shuffle", mode])
        self.status?.shuffleMode = mode
    }

    func toggleRepeat() {
        guard let status else { return }
        let mode = PlaylistModeCycle.nextRepeat(status.repeatMode)
        send(["playlist", "repeat", mode])
        self.status?.repeatMode = mode
    }

    private func send(_ args: [Any], to playerID: String? = nil) {
        guard let id = playerID ?? selectedID, let coordinator else { return }
        commandGeneration += 1
        os_log(.info, log: logger, "→ %{public}s %{public}s", id, args.map { "\($0)" }.joined(separator: " "))
        coordinator.sendJSONRPCCommandDirect(Self.request([id, args])) { _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    private static func request(_ params: [Any]) -> [String: Any] {
        ["id": 1, "method": "slim.request", "params": params]
    }
}
