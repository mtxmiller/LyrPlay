import SwiftUI
import os.log

/// A SlimBrowse drill target — a resolved Jive command ready to fire.
///
/// `Identifiable` for `.fullScreenCover(item:)`; `Hashable` (by `id`) for
/// `navigationDestination(for:)`. Equality is identity-only because the
/// `params` bag is `[String: Any]` and not itself Hashable — every tap
/// produces a fresh target, which is the desired navigation behaviour.
struct JiveCommand: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let cmd: [String]
    let params: [String: Any]

    static func == (lhs: JiveCommand, rhs: JiveCommand) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Recursive SlimBrowse view for plugin-contributed shelves
/// (`home-extra-3rdparty`). Fires the Jive command, parses the response as
/// a Jive obj, and renders item rows. Drill items push another
/// `JiveBrowseView`; terminal (audio) items play.
///
/// Presented in a `NavigationStack` from `HomeExtraShelvesView`. Recursion
/// is handled by a single `navigationDestination(for: JiveCommand.self)`
/// declared at the stack root — every level pushes a `JiveCommand` and the
/// destination builder produces the next `JiveBrowseView`.
///
/// v1 supports `go` (drill) and `play` / `playControl` (terminal). `add`
/// and `more` actions are deferred (bd `LMS_StreamTest-amh`).
struct JiveBrowseView: View {
    let command: JiveCommand
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var items: [JiveItem] = []
    @State private var baseActions: [String: JiveItemAction] = [:]
    @State private var loading = true

    /// SlimBrowse pagination — one page, generous cap. Plugin shelves are
    /// curated lists, not full libraries.
    private static let pageCount = 200

    private let logger = OSLog(subsystem: "com.lmsstream", category: "JiveBrowseView")

    var body: some View {
        TVScreen {
            Group {
                if loading {
                    ProgressView()
                        .scaleEffect(2.0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    emptyView
                } else {
                    list
                }
            }
        }
        .navigationTitle(command.title)
        .task { await load() }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("Nothing here")
                .font(.largeTitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        TVList {
            ForEach(items) { item in
                row(for: item)
                    .tvListRow()
            }
        }
    }

    @ViewBuilder
    private func row(for item: JiveItem) -> some View {
        switch item.dispatch(base: baseActions) {
        case .drill(let cmd, let params):
            NavigationLink(value: JiveCommand(title: item.text, cmd: cmd, params: params)) {
                mediaRow(for: item, symbol: "music.note")
            }
            .buttonStyle(.plain)
        case .play(let cmd, let params):
            Button {
                play(cmd: cmd, params: params, title: item.text)
            } label: {
                mediaRow(for: item, symbol: "play.circle")
            }
            .buttonStyle(.plain)
        case .none:
            mediaRow(for: item, symbol: "music.note")
        }
    }

    private func mediaRow(for item: JiveItem, symbol: String) -> some View {
        MediaRow(
            primary: item.text,
            secondary: item.subtitle,
            artworkURL: item.iconURL(settings: settings),
            placeholderSymbol: symbol
        )
    }

    // MARK: - Networking

    @MainActor
    private func load() async {
        let args: [Any] = command.cmd + [0, Self.pageCount] + Self.cliParams(command.params)
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, args]
        ]
        let response = await coordinator.sendJSONRPCCommand(request)
        guard let result = response["result"] as? [String: Any] else {
            os_log(.error, log: logger, "❌ JiveBrowse '%{public}s': invalid response", command.title)
            loading = false
            return
        }
        let (base, parsed) = JiveItem.parseObj(result)
        baseActions = base
        items = parsed
        loading = false
        os_log(.info, log: logger, "✅ JiveBrowse '%{public}s': %d items", command.title, parsed.count)
    }

    private func play(cmd: [String], params: [String: Any], title: String) {
        let args: [Any] = cmd + Self.cliParams(params)
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, args]
        ]
        coordinator.sendJSONRPCCommandDirect(request) { _ in }
        os_log(.info, log: logger, "▶️ JiveBrowse play: %{public}s", title)
    }

    /// Convert a Jive params bag into LMS CLI `key:value` strings.
    static func cliParams(_ params: [String: Any]) -> [String] {
        params.map { "\($0.key):\($0.value)" }
    }
}
