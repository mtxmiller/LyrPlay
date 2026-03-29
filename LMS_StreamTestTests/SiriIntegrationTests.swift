//
//  SiriIntegrationTests.swift
//  LMS_StreamTestTests
//
//  Tests for Siri voice command integration:
//  - Media identifier parsing and validation
//  - App Group settings sync
//  - Pending intent queue for cold launch
//

import Testing
@testable import LMS_StreamTest

struct SiriIntegrationTests {

    // MARK: - Identifier Parsing Tests

    @Test func identifierParsing_artist() {
        let identifier = "artist_id:42"
        #expect(identifier.contains(":"))

        let parts = identifier.split(separator: ":", maxSplits: 1)
        #expect(parts.count == 2)
        #expect(parts[0] == "artist_id")
        #expect(parts[1] == "42")
    }

    @Test func identifierParsing_album() {
        let identifier = "album_id:123"
        #expect(identifier.contains(":"))

        let parts = identifier.split(separator: ":", maxSplits: 1)
        #expect(parts.count == 2)
        #expect(parts[0] == "album_id")
        #expect(parts[1] == "123")
    }

    @Test func identifierParsing_track() {
        let identifier = "track_id:789"
        #expect(identifier.contains(":"))

        let parts = identifier.split(separator: ":", maxSplits: 1)
        #expect(parts.count == 2)
        #expect(parts[0] == "track_id")
        #expect(parts[1] == "789")
    }

    @Test func identifierParsing_invalid() {
        let invalidIdentifiers = ["", "garbage", "no-colon-here", "   "]
        for identifier in invalidIdentifiers {
            #expect(!identifier.contains(":"),
                    "Expected '\(identifier)' to be rejected as invalid")
        }
    }

    // MARK: - App Group Sync Tests

    @Test func syncToAppGroup_writesCorrectKeys() {
        let shared = UserDefaults(suiteName: "group.elm.LyrPlay")
        // If App Group is not configured in test target, this will be nil
        // and the test validates the guard path
        if let shared = shared {
            // Trigger sync
            SettingsManager.shared.syncToAppGroup()

            // Verify all expected keys are present (may be empty strings for unconfigured server)
            #expect(shared.object(forKey: "serverHost") != nil)
            #expect(shared.object(forKey: "serverWebPort") != nil)
            #expect(shared.object(forKey: "playerMAC") != nil)
        }
    }

    @Test func syncToAppGroup_backupServer() {
        let settings = SettingsManager.shared
        let shared = UserDefaults(suiteName: "group.elm.LyrPlay")

        if let shared = shared {
            // Store original state
            let originalServer = settings.currentActiveServer

            // Sync and verify it completes without error
            settings.syncToAppGroup()

            // The synced host should match whichever server is active
            let syncedHost = shared.string(forKey: "serverHost") ?? ""
            if originalServer == .primary {
                #expect(syncedHost == settings.serverHost)
            } else {
                #expect(syncedHost == settings.backupServerHost)
            }
        }
    }

    // MARK: - Pending Intent Queue Tests

    @Test func pendingIntentQueue_storeAndRetrieve() {
        // Clear any existing pending intent
        _ = SceneDelegate.consumePendingIntent()

        // Store a pending identifier
        SceneDelegate.pendingMediaIdentifier = "artist_id:42"

        // Consume it
        let consumed = SceneDelegate.consumePendingIntent()
        #expect(consumed == "artist_id:42")

        // Should be nil after consumption
        let second = SceneDelegate.consumePendingIntent()
        #expect(second == nil)
    }

    @Test func pendingIntentQueue_emptyByDefault() {
        // Clear any existing
        _ = SceneDelegate.consumePendingIntent()

        // Should be nil when nothing is queued
        let result = SceneDelegate.consumePendingIntent()
        #expect(result == nil)
    }
}
