import Foundation
import os.log

/// Fires resolved SlimBrowse (Jive) actions for the tvOS plugin-browse views.
///
/// One place for the `slim.request` wire format — shared by `JiveBrowseView`
/// (drill-in list) and `HomeExtraShelf` (plugin shelf tiles) so `go` / `play` /
/// `add` dispatch is not hand-rolled per call site. Param serialisation lives
/// on `ResolvedJiveAction.paramArgs` (it is pure and unit-tested).
///
/// Two entry points:
///   - `fetch` — a `go`-style action whose response is a browsable level.
///   - `fire`  — a `play` / `add` action: fire-and-forget, no response to render.
struct JiveDispatcher {
    let coordinator: SlimProtoCoordinator
    /// The connected player's id — plugin actions are player-scoped.
    let playerID: String

    private static let logger = OSLog(subsystem: "com.lmsstream", category: "JiveDispatcher")

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
