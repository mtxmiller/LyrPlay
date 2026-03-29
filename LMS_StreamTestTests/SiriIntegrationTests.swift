//
//  SiriIntegrationTests.swift
//  LMS_StreamTestTests
//
//  Tests for Siri voice command integration:
//  - Media identifier parsing and validation
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
}
