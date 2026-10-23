import Foundation

/// JavaScript that makes Material's live link to LMS (cometd long-polling)
/// start over, for the moments Material cannot recover by itself (bd toz7).
///
/// Device log 2026-10-21 21:35 (build 17): after airplane mode, SlimProto
/// reconnected on cellular at 21:35:10 and Wi-Fi took over two seconds
/// later. Material's reconnect request went out in between, on the cellular
/// path, and the handover orphaned it: in flight forever, never answered.
/// Material showed its red icon until that request hit its own timeout at
/// 21:36:19 (LMS's 60 s long-poll plus the client's 10 s network allowance),
/// and the lock-screen/offline UI had long moved on.
///
/// Nothing in Material can cut such a request: its own `reconnect` (and the
/// check this app used to run on foreground) calls `cometd.connectNow()`,
/// which throws "Concurrent /meta/connect requests not allowed" while the
/// orphan is in flight. And even a reconnect that does reach LMS is held
/// silently for up to 60 s when LMS has no news for it (Slim/Web/Cometd.pm,
/// LONG_POLLING_TIMEOUT), so `lmsIsConnected` stays false meanwhile.
///
/// What this script does, in Material 6.4.x's own terms (server.js):
/// 1. `clearListeners()` + `disconnect()` on the old `cometd` instance, so
///    its orphaned request and its retry timers are inert when they fire
///    (no listeners, state "disconnected") and LMS drops the old client id.
/// 2. `connectToCometD()` on Material's lms-server component: a fresh cometd
///    instance, a new handshake, and all subscriptions re-made by Material's
///    own handshake listener. The first connect reply then sets
///    `lmsIsConnected` and re-subscribes the current player.
///
/// `force` false only acts when Material already reports the link lost
/// (`lmsIsConnected === false`). `force` true restarts the link whatever
/// Material believes: used when our own SlimProto socket just reconnected,
/// since whatever orphaned ours has likely orphaned Material's too, and
/// Material would not find out for 70 s.
///
/// Returns a short word for the log: `not-connected-yet` (Material still
/// loading or handshaking, left alone), `connected`, `no-server` (Material's
/// internals not where expected: a newer skin), `reconnected`,
/// `reconnected-after-loss`.
enum MaterialReconnect {
    static func script(force: Bool) -> String {
        return """
        (function (force) {
            if (typeof lmsIsConnected === 'undefined') { return 'not-connected-yet'; }
            if (!force && lmsIsConnected) { return 'connected'; }
            var root = (typeof app !== 'undefined' && app && app.$children) ? app : null;
            function find(v) {
                if (!v) { return null; }
                if (v.cometd && typeof v.connectToCometD === 'function') { return v; }
                var kids = v.$children || [];
                for (var i = 0; i < kids.length; i++) { var r = find(kids[i]); if (r) { return r; } }
                return null;
            }
            var server = find(root);
            if (!server) { return 'no-server'; }
            var old = server.cometd;
            try { old.clearListeners(); } catch (e) {}
            try { old.disconnect(); } catch (e) {}
            server.connectToCometD();
            return force ? 'reconnected' : 'reconnected-after-loss';
        })(\(force ? "true" : "false"));
        """
    }
}
