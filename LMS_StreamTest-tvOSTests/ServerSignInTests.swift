import Testing
import Foundation
import SwiftUI
@testable import LMS_StreamTest_tvOS

/// bd dtz: sign-in for LMS servers with password protection on.
struct ServerSignInTests {

    @Test func needsSignIn_onlyFor401() {
        #expect(ServerSetup.needsSignIn(.webPortFailure("HTTP Error 401")))
        #expect(!ServerSetup.needsSignIn(.webPortFailure("HTTP Error 404")))
        #expect(!ServerSetup.needsSignIn(.webPortFailure("HTTP connection failed: timed out")))
        #expect(!ServerSetup.needsSignIn(.slimProtoPortFailure("refused")))
        #expect(!ServerSetup.needsSignIn(.success))
        #expect(!ServerSetup.needsSignIn(.timeout))
    }

    /// bd 7e4/8ch: the login never goes in an artwork URL.
    @Test func artworkURL_hasNoCredentials() throws {
        let url = try #require(LMSArtworkURL.cover(coverID: "abc", fallbackID: nil, settings: .shared))
        #expect(url.user == nil)
        #expect(url.password == nil)
    }

    /// The login header goes only to the active LMS server, never to other hosts.
    @Test func artworkRequest_otherHostGetsNoAuthorization() throws {
        let url = try #require(URL(string: "https://images.example.com/cover.jpg"))
        let request = CachedAsyncImage<EmptyView>.request(for: url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
