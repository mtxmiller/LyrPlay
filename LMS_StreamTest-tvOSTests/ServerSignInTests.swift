import Testing
import Foundation
import SwiftUI
@testable import LMS_StreamTest_tvOS

/// bd dtz: sign-in for LMS servers with password protection on.
/// Serialized: the tests below set a server and login on the shared
/// SettingsManager (not saved) and put the old values back.
@Suite(.serialized)
struct ServerSignInTests {

    @Test func needsSignIn_onlyFor401() {
        #expect(ServerSetup.needsSignIn(.webPortFailure("HTTP Error 401")))
        #expect(!ServerSetup.needsSignIn(.webPortFailure("HTTP Error 404")))
        #expect(!ServerSetup.needsSignIn(.webPortFailure("HTTP connection failed: timed out")))
        #expect(!ServerSetup.needsSignIn(.slimProtoPortFailure("refused")))
        #expect(!ServerSetup.needsSignIn(.success))
        #expect(!ServerSetup.needsSignIn(.timeout))
    }

    /// bd 7e4/8ch: the login never goes in an artwork URL, even when one is saved.
    @Test func artworkURL_hasNoCredentials() throws {
        try withLogin {
            let url = try #require(LMSArtworkURL.cover(coverID: "abc", fallbackID: nil, settings: .shared))
            #expect(url.user == nil)
            #expect(url.password == nil)
        }
    }

    /// The login header goes to the active LMS server only.
    @Test func artworkRequest_authorizationOnlyForActiveServer() throws {
        try withLogin {
            let own = try #require(URL(string: "http://192.0.2.10:9002/music/abc/cover.jpg"))
            #expect(CachedAsyncImage<EmptyView>.request(for: own).value(forHTTPHeaderField: "Authorization") != nil)

            let otherPort = try #require(URL(string: "http://192.0.2.10:9000/music/abc/cover.jpg"))
            #expect(CachedAsyncImage<EmptyView>.request(for: otherPort).value(forHTTPHeaderField: "Authorization") == nil)

            let otherHost = try #require(URL(string: "https://images.example.com/cover.jpg"))
            #expect(CachedAsyncImage<EmptyView>.request(for: otherHost).value(forHTTPHeaderField: "Authorization") == nil)
        }
    }

    /// Two servers on one address (lms + lms-demo): the saved login belongs
    /// to one host + port only.
    @Test func savedLogin_matchesHostAndPort() {
        withLogin {
            let settings = SettingsManager.shared
            #expect(ServerSetup.savedLogin(for: "192.0.2.10", port: 9002, settings: settings).username == "tester")
            #expect(ServerSetup.savedLogin(for: "192.0.2.10", port: 9000, settings: settings).username.isEmpty)
            #expect(ServerSetup.savedLogin(for: "192.0.2.11", port: 9002, settings: settings).username.isEmpty)
        }
    }

    /// Sets a test server (192.0.2.10:9002, a documentation address) and
    /// login on the shared settings for `body`, then restores the old values.
    private func withLogin<T>(_ body: () throws -> T) rethrows -> T {
        let settings = SettingsManager.shared
        let saved = (settings.currentActiveServer, settings.serverHost, settings.serverWebPort,
                     settings.serverUsername, settings.serverPassword)
        defer {
            settings.currentActiveServer = saved.0
            settings.serverHost = saved.1
            settings.serverWebPort = saved.2
            settings.serverUsername = saved.3
            settings.serverPassword = saved.4
        }
        settings.currentActiveServer = .primary
        settings.serverHost = "192.0.2.10"
        settings.serverWebPort = 9002
        settings.serverUsername = "tester"
        settings.serverPassword = "secret"
        return try body()
    }
}
