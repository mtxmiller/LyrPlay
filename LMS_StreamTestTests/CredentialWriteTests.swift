import Testing
import Security
@testable import LMS_StreamTest

/// GH #146: CarPlay started LyrPlay on a locked phone, the Keychain read
/// failed, and the first settings save deleted the server password.
struct CredentialWriteTests {

    @Test func aUsernameIsSaved() {
        #expect(SettingsManager.credentialWrite(username: "eric", unreadable: false) == .save)
    }

    @Test func aUsernameTypedWhileUnreadableIsStillSaved() {
        #expect(SettingsManager.credentialWrite(username: "eric", unreadable: true) == .save)
    }

    @Test func noLoginDeletesTheItem() {
        #expect(SettingsManager.credentialWrite(username: "", unreadable: false) == .delete)
    }

    @Test func emptyAfterALockedLaunchKeepsTheStoredPassword() {
        #expect(SettingsManager.credentialWrite(username: "", unreadable: true) == .keep)
    }

    @Test func passwordsAreReadableAfterFirstUnlock() {
        #expect(KeychainManager.accessibility == kSecAttrAccessibleAfterFirstUnlock)
    }
}
