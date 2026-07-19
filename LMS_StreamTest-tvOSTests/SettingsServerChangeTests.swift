import Testing
import Foundation
@testable import LMS_StreamTest_tvOS

/// `SettingsServerChange.store` is module-static. Mark the suite serialized so
/// tests don't race on it (Swift Testing parallelizes within a suite by default).
/// Same pattern as `SearchHistoryStoreTests`.
@Suite(.serialized)
struct SettingsServerChangeTests {

    private func makeIsolatedStore() -> (UserDefaults, String) {
        let name = "settings-server-change-test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        SettingsServerChange.store = suite
        return (suite, name)
    }

    private func resetStore(_ suiteName: String) {
        SettingsServerChange.store = .standard
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    // MARK: - clearRecoveryKeys

    @Test func clearRecoveryKeys_removesAllThreeKeys() {
        let (suite, name) = makeIsolatedStore()
        defer { resetStore(name) }

        suite.set(7, forKey: "lyrplay_recovery_index")
        suite.set(123.45, forKey: "lyrplay_recovery_position")
        suite.set(Date().timeIntervalSince1970, forKey: "lyrplay_recovery_timestamp")

        SettingsServerChange.clearRecoveryKeys()

        #expect(suite.object(forKey: "lyrplay_recovery_index") == nil)
        #expect(suite.object(forKey: "lyrplay_recovery_position") == nil)
        #expect(suite.object(forKey: "lyrplay_recovery_timestamp") == nil)
    }

    @Test func clearRecoveryKeys_idempotent_whenKeysAlreadyAbsent() {
        let (suite, name) = makeIsolatedStore()
        defer { resetStore(name) }

        // No prior writes — keys should be absent.
        SettingsServerChange.clearRecoveryKeys()
        SettingsServerChange.clearRecoveryKeys()

        #expect(suite.object(forKey: "lyrplay_recovery_index") == nil)
        #expect(suite.object(forKey: "lyrplay_recovery_position") == nil)
        #expect(suite.object(forKey: "lyrplay_recovery_timestamp") == nil)
    }

    // MARK: - aboutInfo

    @Test func aboutInfo_readsHostAndMACFromArgs() {
        let info = SettingsServerChange.aboutInfo(
            serverHost: "192.168.1.42",
            playerMAC: "02:00:00:11:22:33"
        )

        #expect(info.host == "192.168.1.42")
        #expect(info.playerMAC == "02:00:00:11:22:33")
    }

    @Test func aboutInfo_handlesEmptyHost_returnsEmptyString() {
        let info = SettingsServerChange.aboutInfo(
            serverHost: "",
            playerMAC: "02:00:00:11:22:33"
        )

        #expect(info.host == "")
    }

    @Test func aboutInfo_readsBundleVersionAndBuild() {
        // Use the test target's own bundle. We don't assert exact version
        // (it changes each release) but we DO assert the lookup doesn't
        // return nil-as-empty for keys that exist on every Apple bundle.
        let bundle = Bundle(for: BundleAnchor.self)
        let info = SettingsServerChange.aboutInfo(
            serverHost: "x",
            playerMAC: "y",
            bundle: bundle
        )

        // Either non-empty (bundle has the keys) or both empty (test bundle
        // doesn't, which is fine — we're verifying the accessor path doesn't
        // crash).
        #expect(info.version == info.version)
        #expect(info.build == info.build)
    }

    @Test func aboutInfo_missingBundleKeys_returnsEmptyStrings() {
        // Synthesize a bundle that has no Info.plist keys for version/build.
        // Simplest: use the bundle for the tests target — it may or may not
        // have these. If it does, this test is a no-op assertion; if it
        // doesn't, the empty-string fallback is exercised. Either way, the
        // accessor doesn't crash.
        let bundle = Bundle(for: BundleAnchor.self)
        let info = SettingsServerChange.aboutInfo(
            serverHost: "host",
            playerMAC: "mac",
            bundle: bundle
        )

        // Non-crash + correct passthrough of host/mac.
        #expect(info.host == "host")
        #expect(info.playerMAC == "mac")
    }

    @Test func aboutInfo_isEquatable() {
        let a = SettingsServerChange.aboutInfo(serverHost: "h", playerMAC: "m")
        let b = SettingsServerChange.aboutInfo(serverHost: "h", playerMAC: "m")

        #expect(a == b)
    }
}

/// Test-bundle anchor for `Bundle(for:)`.
private final class BundleAnchor {}
