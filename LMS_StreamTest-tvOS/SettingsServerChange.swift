import Foundation

/// Pure-Foundation helpers for the tvOS Settings screen.
///
/// Two responsibilities, both extracted as a testable seam (E2 from
/// /plan-eng-review 2026-05-07):
///   - `clearRecoveryKeys()` removes the 3 UserDefaults keys that drive
///     position/playlist recovery on reconnect. Called when the user changes
///     LMS server, because the saved index points to the OLD server's
///     playlist (CLAUDE.md rule #4 atomicity).
///   - `aboutInfo(...)` returns the read-only data shown in Settings ▸ About.
///
/// Mirrors `SearchHistoryStore` (98q.8) and `VisualizerEngine` (98q.7) — keep
/// the logic in pure Swift so it's unit-testable without SwiftUI infrastructure.
enum SettingsServerChange {
    /// Backing store. Production reads/writes `.standard`; tests assign a
    /// fresh `UserDefaults(suiteName:)` for isolation.
    static var store: UserDefaults = .standard

    private static let recoveryKeys = [
        "lyrplay_recovery_index",
        "lyrplay_recovery_position",
        "lyrplay_recovery_timestamp",
    ]

    /// Removes the 3 recovery-state keys. Idempotent — safe to call when keys
    /// are already absent. Used on server change so the new connect is treated
    /// as fresh (no playlist-jump to a stale index).
    static func clearRecoveryKeys() {
        for key in recoveryKeys {
            store.removeObject(forKey: key)
        }
    }

    struct AboutInfo: Equatable {
        let version: String
        let build: String
        let host: String
        let playerMAC: String
    }

    /// Reads version + build from the bundle, host + MAC from caller-provided
    /// strings (caller pulls from `SettingsManager.shared`). Bundle is
    /// injected so tests can supply a fake.
    static func aboutInfo(
        serverHost: String,
        playerMAC: String,
        bundle: Bundle = .main
    ) -> AboutInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return AboutInfo(
            version: version,
            build: build,
            host: serverHost,
            playerMAC: playerMAC
        )
    }
}
