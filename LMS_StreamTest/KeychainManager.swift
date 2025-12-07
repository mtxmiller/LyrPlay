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
            kSecAttrService as String: "LyrPlay-LMS-Auth",
            kSecValueData as String: data
        ]

        // Delete any existing item first
        SecItemDelete(query as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecSuccess {
            os_log(.info, log: logger, "✅ Credentials saved successfully for %{public}s", serverKey.rawValue)
            return true
        } else {
            os_log(.error, log: logger, "❌ Failed to save credentials: %d", status)
            return false
        }
    }

    /// Load credentials from Keychain
    /// - Parameter serverKey: Which server (primary or backup)
    /// - Returns: Tuple of (username, password) or nil if not found
    func load(for serverKey: ServerKey) -> (username: String, password: String)? {
        os_log(.debug, log: logger, "Loading credentials for %{public}s", serverKey.rawValue)

        // Build Keychain query
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: serverKey.rawValue,
            kSecAttrService as String: "LyrPlay-LMS-Auth",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder().decode([String: String].self, from: data),
              let username = credentials["username"],
              let password = credentials["password"] else {

            if status == errSecItemNotFound {
                os_log(.debug, log: logger, "No credentials found for %{public}s", serverKey.rawValue)
            } else {
                os_log(.error, log: logger, "❌ Failed to load credentials: %d", status)
            }
            return nil
        }

        os_log(.info, log: logger, "✅ Credentials loaded for %{public}s (username: %{public}s)",
               serverKey.rawValue, username)
        return (username: username, password: password)
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

    /// Check if credentials exist for a server
    /// - Parameter serverKey: Which server (primary or backup)
    /// - Returns: True if credentials are stored
    func hasCredentials(for serverKey: ServerKey) -> Bool {
        return load(for: serverKey) != nil
    }

    /// Clear all LMS credentials (for reset/logout)
    func clearAll() {
        os_log(.info, log: logger, "Clearing all LMS credentials")
        delete(for: .primary)
        delete(for: .backup)
    }
}
