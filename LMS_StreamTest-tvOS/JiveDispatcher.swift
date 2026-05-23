import Foundation
import os.log

/// What `JiveDispatcher.decide(...)` returns: the classified intent for a
/// row tap, before the caller routes it.
///
/// The call site interprets the case — a tvOS view in a programmatic-path
/// `NavigationStack` may push the drill; a horizontal shelf tile (no nav stack
/// of its own) may open a `.fullScreenCover`. Both fire `.terminal` the same way.
enum JiveDecision {
    /// The row's primary action is play-class (or carries a `nowplaying` nav
    /// hint). Fire the action; route by its `nextWindow` if present, else
    /// default-dismiss for play-class (E6: enqueue actions stay put — this
    /// case only fires for play-class so default-dismiss is correct).
    case terminal(ResolvedJiveAction)
    /// The row's primary action is browse-class. Push a child `JiveBrowseView`
    /// for the returned command — `JiveCommand.title` carries the item's text
    /// for the next level's nav title.
    case drill(JiveCommand)
    /// Defensive: the row has no usable `goAction` / `go` action. Tap is a
    /// no-op; logging is the caller's responsibility.
    case unresolved
}

/// Fires resolved SlimBrowse (Jive) actions for the tvOS plugin-browse views.
///
/// One place for the `slim.request` wire format — shared by `JiveBrowseView`
/// (drill-in list) and `HomeExtraShelf` (plugin shelf tiles) so `go` / `play` /
/// `add` dispatch is not hand-rolled per call site. Param serialisation lives
/// on `ResolvedJiveAction.paramArgs` (it is pure and unit-tested).
///
/// Three entry points:
///   - `decide` — classify a row tap into `.terminal` / `.drill` / `.unresolved`.
///   - `fetch`  — a `go`-style action whose response is a browsable level.
///   - `fire`   — a `play` / `add` action: fire-and-forget, no response to render.
struct JiveDispatcher {
    let coordinator: SlimProtoCoordinator
    /// The connected player's id — plugin actions are player-scoped.
    let playerID: String

    private static let logger = OSLog(subsystem: "com.lmsstream", category: "JiveDispatcher")

    /// Classify a row tap into `.terminal` / `.drill` / `.unresolved`. The
    /// resolved action is built from `item.tapActionName` (`goAction ?? "go"`)
    /// merged against `base`; if that doesn't resolve, we fall back to the
    /// section's `base.go` template directly.
    ///
    /// Classification rule (E5-locked, cmd-first):
    ///   terminal iff
    ///     `action.isPlayVerb`              (predicate on the resolved cmd)
    ///     OR `item.hasLeafHint`            (style:itemplay, touchToPlay, type=audio/track)
    ///     OR `action.nextWindow == "nowplaying"` (server says go to Now Playing)
    ///
    /// The `cmd` is decisive — a known browse verb (`items`, `tracks`, …)
    /// always classifies as drill regardless of leaf hints (false-positive
    /// guard: a container item carrying a leaf-ish `type` is still a container).
    ///
    /// Static so unit tests can call it without constructing a coordinator —
    /// the function doesn't use instance state.
    static func decide(item: JiveItem, base: [String: JiveItemAction]) -> JiveDecision {
        guard let action = item.resolvedAction(named: item.tapActionName, base: base)
            ?? item.resolvedAction(named: "go", base: base) else {
            return .unresolved
        }
        // Browse-cmd path: cmd-says-browse normally beats everything (the
        // false-positive guard against a container with a leaf-ish type).
        // BUT: when the server explicitly marks the item as a streamable
        // favorite (Bandcamp Weekly's goAction:"playControl" pattern — the
        // tap action resolves to a browse cmd, yet base.play exists as the
        // real play), prefer base.play. This is "translate jivelite's
        // playControl context-menu tap to Apple TV's center-button-plays."
        if action.isBrowseVerb {
            if item.hasLeafHint,
               let play = item.resolvedAction(named: "play", base: base),
               play.isPlayVerb {
                return .terminal(play)
            }
            return .drill(JiveCommand(title: item.text, cmd: action.cmd, params: action.params))
        }
        let isTerminal = action.isPlayVerb
            || item.hasLeafHint
            || action.nextWindow == "nowplaying"
        if isTerminal {
            return .terminal(action)
        } else {
            return .drill(JiveCommand(title: item.text, cmd: action.cmd, params: action.params))
        }
    }

    /// Fetch a `go`-style action and return the raw `result` dict. The caller
    /// (`JiveBrowseView`) parses it via `JiveItem.parseObj`; the response
    /// decides drill (carries `item_loop`) vs terminal.
    @MainActor
    func fetch(_ action: ResolvedJiveAction, page: Int) async -> [String: Any]? {
        let args: [Any] = action.cmd + [0, page] + action.paramArgs
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, args]
        ]
        let response = await coordinator.sendJSONRPCCommand(request)
        return response["result"] as? [String: Any]
    }

    /// Fire a `play` / `add` action as a fire-and-forget SlimBrowse request.
    /// Post-action navigation (`nextWindow`) is the caller's concern — it owns
    /// the view hierarchy this dispatcher does not.
    func fire(_ action: ResolvedJiveAction, label: String) {
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, action.cliArgs]
        ]
        coordinator.sendJSONRPCCommandDirect(request) { _ in }
        os_log(.info, log: Self.logger, "▶️ Jive action fired: %{public}s", label)
    }
}
