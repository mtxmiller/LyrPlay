// File: KeychainManager.swift
// Secure credential storage using iOS Keychain Services
import Foundation
import Security
import os.log

/// Manages secure storage of LMS server credentials using iOS Keychain
class KeychainManager {

    private let logger = OSLog(subsystem: "com.lmsstream", category: "KeychainManager")

    // MARK: - Singleton
    static let shared = KeychainManager()

    private init() {
        os_log(.info, log: logger, "KeychainManager initialized")
    }

    // MARK: - Server Keys
    enum ServerKey: String {
        case primary = "lyrplay.server.primary"
        case backup = "lyrplay.server.backup"
    }

    // MARK: - Public Methods

    /// Save credentials to Keychain
    /// - Parameters:
    ///   - username: Username for LMS server
    ///   - password: Password for LMS server
    ///   - serverKey: Which server (primary or backup)
    /// - Returns: True if saved successfully
    @discardableResult
    func save(username: String, password: String, for serverKey: ServerKey) -> Bool {
        // Don't save empty credentials
        guard !username.isEmpty else {
            os_log(.debug, log: logger, "Skipping save - empty username for %{public}s", serverKey.rawValue)
            return delete(for: serverKey) // Clear any existing credentials
        }

        os_log(.info, log: logger, "Saving credentials for %{public}s (username: %{public}s)",
               serverKey.rawValue, username)

        // Encode credentials as dictionary
        let credentials: [String: String] = [
            "username": username,
            "password": password
        ]

        guard let data = try? JSONEncoder().encode(credentials) else {
            os_log(.error, log: logger, "Failed to encode credentials")
            return false
        }

        // Build Keychain query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: serverKey.rawValue,
            kSecAttrService as String: "LyrPlay-LMS-Auth"
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: Self.accessibility
        ]

        // Update in place; add only when there is none. (Delete-then-add lost
        // the item whenever the add failed, e.g. on a locked phone.)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }

        if status == errSecSuccess {
            os_log(.info, log: logger, "✅ Credentials saved successfully for %{public}s", serverKey.rawValue)
            return true
        } else {
            os_log(.error, log: logger, "❌ Failed to save credentials: %d", status)
            return false
        }
    }

    /// Readable once the device has been unlocked after a restart, also while
    /// it is locked again: CarPlay and background launches start the app on a
    /// locked phone. The old default (when unlocked) failed those reads and the
    /// next settings save deleted the password (GH #146).
    static let accessibility = kSecAttrAccessibleAfterFirstUnlock

    enum LoadResult {
        case found(username: String, password: String)
        case notFound
        /// The item may exist but can't be read now (device locked, or another
        /// Keychain error): the caller must not treat this as "no credentials".
        case unavailable(OSStatus)
    }

    /// Load credentials from Keychain
    /// - Parameter serverKey: Which server (primary or backup)
    /// - Returns: Tuple of (username, password) or nil if not found or unreadable
    func load(for serverKey: ServerKey) -> (username: String, password: String)? {
        if case let .found(username, password) = loadResult(for: serverKey) {
            return (username: username, password: password)
        }
        return nil
    }

    /// Load credentials, telling "none stored" apart from "can't read now".
    /// A readable item saved with the old accessibility is moved to
    /// `accessibility` so the next locked launch can read it.
    func loadResult(for serverKey: ServerKey) -> LoadResult {
        os_log(.debug, log: logger, "Loading credentials for %{public}s", serverKey.rawValue)

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: serverKey.rawValue,
            kSecAttrService as String: "LyrPlay-LMS-Auth"
        ]
        var query = base
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            os_log(.debug, log: logger, "No credentials found for %{public}s", serverKey.rawValue)
            return .notFound
        }
        guard status == errSecSuccess else {
            os_log(.error, log: logger, "❌ Can't read credentials for %{public}s now: %d%{public}s",
                   serverKey.rawValue, status,
                   status == errSecInteractionNotAllowed ? " (device locked)" : "")
            return .unavailable(status)
        }
        guard let item = result as? [String: Any],
              let data = item[kSecValueData as String] as? Data,
              let credentials = try? JSONDecoder().decode([String: String].self, from: data),
              let username = credentials["username"],
              let password = credentials["password"] else {
            // Read fine but unusable: nothing to protect, a save may replace it.
            os_log(.error, log: logger, "❌ Stored credentials for %{public}s are unreadable", serverKey.rawValue)
            return .notFound
        }

        if let current = item[kSecAttrAccessible as String] as? String,
           current != Self.accessibility as String {
            let update = SecItemUpdate(base as CFDictionary,
                                       [kSecAttrAccessible as String: Self.accessibility] as CFDictionary)
            if update == errSecSuccess {
                os_log(.default, log: logger, "🔑 Credentials for %{public}s moved to after-first-unlock access", serverKey.rawValue)
            } else {
                os_log(.error, log: logger, "❌ Couldn't move credentials for %{public}s to after-first-unlock access: %d",
                       serverKey.rawValue, update)
            }
        }

        os_log(.info, log: logger, "✅ Credentials loaded for %{public}s (username: %{public}s)",
               serverKey.rawValue, username)
        return .found(username: username, password: password)
    }

    /// Delete credentials from Keychain
    /// - Parameter serverKey: Which server (primary or backup)
    /// - Returns: True if deleted successfully (or didn't exist)
    @discardableResult
    func delete(for serverKey: ServerKey) -> Bool {
        os_log(.info, log: logger, "Deleting credentials for %{public}s", serverKey.rawValue)

        // Build Keychain query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: serverKey.rawValue,
            kSecAttrService as String: "LyrPlay-LMS-Auth"
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status == errSecSuccess || status == errSecItemNotFound {
            os_log(.info, log: logger, "✅ Credentials deleted for %{public}s", serverKey.rawValue)
            return true
        } else {
            os_log(.error, log: logger, "❌ Failed to delete credentials: %d", status)
            return false
        }
    }

}
