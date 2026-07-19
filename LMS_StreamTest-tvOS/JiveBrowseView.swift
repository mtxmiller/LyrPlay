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
    @Binding var path: [BrowseDestination]
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

    /// Press-and-hold menu — secondary per-item affordances. Select now
    /// handles per-track play directly (gi0 fix); the menu provides Play (for
    /// containers — "Play all") and Add. Each button appears only when its
    /// action resolves against item + base.
    ///
    /// Same post-play "stay in browse" rule as `handleSelect`: after fire,
    /// honor in-stack routes (parent/grandparent/refresh) but DON'T dismiss
    /// the cover on nowplaying or absent nextWindow.
    @ViewBuilder
    private func contextMenu(for item: JiveItem) -> some View {
        if let play = item.resolvedAction(named: "play", base: baseActions) {
            Button {
                dispatcher.fire(play, label: item.text)
                if let nw = play.nextWindow {
                    route(nextWindow: nw)
                }
                // No cover-dismiss otherwise — stay in browse after play.
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

    /// Select/OK: ask `JiveDispatcher.decide` to classify the row, then route.
    /// The classifier is `cmd`-first (E2) with leaf hints + `nextWindow:nowplaying`
    /// as secondary signals (E5).
    ///
    /// **Post-play UX (round-2 hardware feedback, supersedes E6's default-dismiss
    /// rule):** after firing a play-class action, the user STAYS in the track
    /// list. `nextWindow` is consulted only for in-stack routes (parent /
    /// grandparent / refresh) and for the explicit `home` escape; `nowplaying`
    /// is informational, no cover dismiss. Same reasoning as `c8q` was dropped:
    /// mherger's stated mental model is "browse is where I live, play is
    /// something I do while staying here."
    private func handleSelect(_ item: JiveItem) {
        switch JiveDispatcher.decide(item: item, base: baseActions) {
        case .terminal(let action):
            dispatcher.fire(action, label: item.text)
            if let nw = action.nextWindow {
                route(nextWindow: nw)
            }
            // No cover-dismiss otherwise — stay on the track list after play.
        case .drill(let cmd):
            path.append(.plugin(cmd))
        case .unresolved:
            os_log(.error, log: logger, "⚠️ '%{public}s' has no usable tap action", item.text)
        }
    }

    /// Honour a `nextWindow` hint. `parent`/`grandparent`/`refresh` resolve
    /// in-stack; `home` is the only escape that dismisses the cover.
    /// `nowplaying` is **informational only** — round-2 hardware feedback
    /// established that users want to stay in the track list after play
    /// (mherger: "browse is where I live"). The server hint that "this goes
    /// to Now Playing" is honored by the server-side play itself; the client
    /// no longer yanks the user out of browse. The Now Playing tab is one
    /// tap away when the user wants it.
    private func route(nextWindow nw: String) {
        switch nw {
        case "home":
            dismissBrowse()
        case "nowplaying":
            break   // stay in browse (c8q reasoning, applied to dismiss too)
        case "parent":
            if path.isEmpty { dismissBrowse() } else { path.removeLast() }
        case "grandparent":
            if path.count >= 2 { path.removeLast(2) } else { dismissBrowse() }
        case "refresh":
            reloadToken += 1
        default:
            break   // unknown / already lowercased
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
