import SwiftUI
import os.log

/// A SlimBrowse drill target — a resolved Jive command ready to fire.
///
/// `Hashable` (by `id`) so it can be a `NavigationStack` path element.
/// Equality is identity-only because the `params` bag is `[String: Any]` and
/// not itself Hashable — every drill produces a fresh target, which is the
/// desired navigation behaviour.
struct JiveCommand: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let cmd: [String]
    let params: [String: Any]

    static func == (lhs: JiveCommand, rhs: JiveCommand) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Recursive SlimBrowse view for plugin-contributed shelves
/// (`home-extra-3rdparty`).
///
/// Interaction model (the `7do` rebuild — see the design doc's "Verified Wire
/// Data" and "Eng Review — Locked Decisions"):
///   - **Select/OK** fires the item's `goAction` (default `"go"`), resolved
///     against the section `base`. If that resolved action carries a
///     `nextWindow` it is terminal — fire it directly and route. Otherwise it
///     is a drill — push a child `JiveBrowseView` whose own `.task` fetches it
///     (one fetch, no double round-trip — "child decides").
///   - **Press-and-hold** opens a context menu: Play / Add. The Siri Remote
///     hardware Play/Pause button is NOT used here — it is global transport
///     control (`ContentView`, D2 invariant 98q.5).
///   - **`nextWindow`** routes post-action: `parent`/`grandparent`/`refresh`
///     in-stack; `nowplaying`/`home` dismiss the whole browse cover.
///
/// Presented in a `NavigationStack(path:)` from `HomeExtraShelvesView`; the
/// `path` binding drives drill + `parent`/`grandparent`, `dismissBrowse`
/// closes the `.fullScreenCover`.
struct JiveBrowseView: View {
    let command: JiveCommand
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager
    /// The enclosing `NavigationStack`'s path — drill appends, `parent` pops.
    @Binding var path: [JiveCommand]
    /// Dismiss the whole browse `.fullScreenCover` (`nowplaying` / `home`).
    let dismissBrowse: () -> Void

    @State private var items: [JiveItem] = []
    @State private var baseActions: [String: JiveItemAction] = [:]
    @State private var loading = true
    @State private var loadError = false
    /// Bumped to re-run `.task` — drives `nextWindow: refresh`.
    @State private var reloadToken = 0

    /// SlimBrowse pagination — one page, generous cap. Plugin shelves are
    /// curated lists, not full libraries.
    private static let pageCount = 200

    private let logger = OSLog(subsystem: "com.lmsstream", category: "JiveBrowseView")

    private var dispatcher: JiveDispatcher {
        JiveDispatcher(coordinator: coordinator, playerID: settings.playerMACAddress)
    }

    var body: some View {
        TVScreen {
            Group {
                if loading {
                    ProgressView()
                        .scaleEffect(2.0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadError {
                    errorView
                } else if items.isEmpty {
                    emptyView
                } else {
                    list
                }
            }
        }
        .navigationTitle(command.title)
        .task(id: reloadToken) { await load() }
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

    /// Shown when the `go` fetch fails (timeout / network / bad response).
    /// A failed drill must not leave a stuck spinner — Retry re-runs `.task`.
    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 96))
                .foregroundStyle(.secondary)
            Text("Couldn't load")
                .font(.largeTitle)
            Button("Retry") { reloadToken += 1 }
                .padding(.top, 8)
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
        Button {
            handleSelect(item)
        } label: {
            MediaRow(
                primary: item.text,
                secondary: item.subtitle,
                artworkURL: item.iconURL(settings: settings),
                placeholderSymbol: iconSymbol(for: item)
            )
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenu(for: item) }
    }

    /// Press-and-hold menu — the sole per-item Play/Add affordance. Each
    /// button appears only when its action resolves against item + base.
    @ViewBuilder
    private func contextMenu(for item: JiveItem) -> some View {
        if let play = item.resolvedAction(named: "play", base: baseActions) {
            Button {
                dispatcher.fire(play, label: item.text)
                if let nw = play.nextWindow { route(nextWindow: nw) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
        }
        if let add = item.resolvedAction(named: item.addActionName, base: baseActions) {
            Button {
                dispatcher.fire(add, label: item.text)
                // Enqueue intents suppress navigating nextWindow — only a
                // `refresh` (re-read the current level) is honoured.
                if add.nextWindow == "refresh" { reloadToken += 1 }
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
        }
    }

    /// Display-only icon from `type` — never gates control flow.
    private func iconSymbol(for item: JiveItem) -> String {
        switch item.type {
        case "playlist":        return "music.note.list"
        case "audio", "track":  return "play.circle"
        default:                return "music.note"
        }
    }

    // MARK: - Select / dispatch

    /// Select/OK: resolve the item's `goAction`. A resolved action with a
    /// `nextWindow` is terminal — fire it and route. Otherwise it is a drill —
    /// push a child level (the child's `.task` does the one and only fetch).
    private func handleSelect(_ item: JiveItem) {
        guard let action = item.resolvedAction(named: item.tapActionName, base: baseActions)
            ?? item.resolvedAction(named: "go", base: baseActions) else {
            os_log(.error, log: logger, "⚠️ '%{public}s' has no usable tap action", item.text)
            return
        }
        if let nw = action.nextWindow {
            // Terminal — fire directly, no push, no empty-spinner flash.
            dispatcher.fire(action, label: item.text)
            route(nextWindow: nw)
        } else {
            // Drill — push a child JiveBrowseView for this command.
            path.append(JiveCommand(title: item.text, cmd: action.cmd, params: action.params))
        }
    }

    /// Honour a `nextWindow` hint. `parent`/`grandparent`/`refresh` resolve
    /// in-stack; `nowplaying`/`home` dismiss the whole browse cover. (The
    /// `nowplaying` tab-switch is deferred — bd LMS_StreamTest-c8q.)
    private func route(nextWindow nw: String) {
        switch nw {
        case "nowplaying", "home":
            dismissBrowse()
        case "parent":
            if path.isEmpty { dismissBrowse() } else { path.removeLast() }
        case "grandparent":
            if path.count >= 2 { path.removeLast(2) } else { dismissBrowse() }
        case "refresh":
            reloadToken += 1
        default:
            break   // unknown / "nowPlaying" already lowercased — no-op
        }
    }

    // MARK: - Networking

    @MainActor
    private func load() async {
        loading = true
        loadError = false
        let action = ResolvedJiveAction(cmd: command.cmd, params: command.params, nextWindow: nil)
        guard let result = await dispatcher.fetch(action, page: Self.pageCount) else {
            os_log(.error, log: logger, "❌ JiveBrowse '%{public}s': fetch failed", command.title)
            items = []
            loading = false
            loadError = true
            return
        }
        let (base, parsed) = JiveItem.parseObj(result)
        baseActions = base
        items = parsed
        loading = false
        os_log(.info, log: logger, "✅ JiveBrowse '%{public}s': %d items", command.title, parsed.count)
    }
}
