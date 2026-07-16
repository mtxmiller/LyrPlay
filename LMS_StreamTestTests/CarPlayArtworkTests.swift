import XCTest
@testable import LMS_StreamTest

/// Unit coverage for `CarPlaySceneDelegate.favoriteArtworkURL(from:host:port:)`,
/// the pure resolver that turns an LMS favorite `icon`/`image` string into a
/// loadable CarPlay artwork URL. Auth is applied as a header at fetch time, so
/// it is intentionally NOT part of the URL here (tvOS's twin embeds credentials).
final class CarPlayArtworkTests: XCTestCase {

    private let host = "192.168.1.8"
    private let port = 9000

    private func resolve(_ icon: String?) -> String? {
        CarPlaySceneDelegate.favoriteArtworkURL(from: icon, host: host, port: port)?.absoluteString
    }

    func testAbsoluteHttpReturnedAsIs() {
        XCTAssertEqual(resolve("http://cdn.example.com/art.png"), "http://cdn.example.com/art.png")
    }

    func testAbsoluteHttpsReturnedAsIs() {
        XCTAssertEqual(resolve("https://cdn.example.com/art.jpg"), "https://cdn.example.com/art.jpg")
    }

    func testLeadingSlashRelativeResolvesToHost() {
        XCTAssertEqual(resolve("/imageproxy/abc/image.png"),
                       "http://192.168.1.8:9000/imageproxy/abc/image.png")
    }

    func testNoSlashRelativeResolvesToHost() {
        XCTAssertEqual(resolve("plugins/RadioParadise/html/icon.png"),
                       "http://192.168.1.8:9000/plugins/RadioParadise/html/icon.png")
    }

    func testPluginIconPathIsNotResized() {
        // Non-music paths pass through unresized (server sends them small).
        XCTAssertFalse(resolve("plugins/RadioParadise/html/icon.png")!.contains("_200x200_"))
    }

    func testMusicCoverNoSlashRewrittenToThumbnail() {
        XCTAssertEqual(resolve("music/7feda868/cover.png"),
                       "http://192.168.1.8:9000/music/7feda868/cover_200x200_o.png")
    }

    func testMusicCoverLeadingSlashRewrittenToThumbnail() {
        XCTAssertEqual(resolve("/music/12345/cover.jpg"),
                       "http://192.168.1.8:9000/music/12345/cover_200x200_o.jpg")
    }

    func testAlreadySizedMusicCoverNotDoubleRewritten() {
        XCTAssertEqual(resolve("music/12345/cover_200x200_o.png"),
                       "http://192.168.1.8:9000/music/12345/cover_200x200_o.png")
    }

    func testHostAndPortInjectedForRelative() {
        let url = CarPlaySceneDelegate.favoriteArtworkURL(from: "/imageproxy/x.png", host: host, port: port)
        XCTAssertEqual(url?.host, "192.168.1.8")
        XCTAssertEqual(url?.port, 9000)
        XCTAssertEqual(url?.scheme, "http")
    }

    func testNilReturnsNil() {
        XCTAssertNil(resolve(nil))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(resolve(""))
    }

    // MARK: - Percent-encoded paths (GH#92 "black antenna icon")
    //
    // A favorite whose icon is set to a URL comes back from LMS as an
    // ALREADY-percent-encoded imageproxy path. URLComponents.path re-encodes
    // the '%' signs (%3A → %253A); the server can't resolve the mangled
    // embedded URL and serves its radio.png fallback instead — so every
    // URL-icon favorite showed the black antenna. The resolver must pass
    // existing escapes through untouched.

    func testImageproxyEscapedURLNotDoubleEncoded() {
        // Real shape from 192.168.1.8 favorite 4425b0b5.0.
        XCTAssertEqual(
            resolve("/imageproxy/https%3A%2F%2Fstation.example%2Flogo.png/image.png"),
            "http://192.168.1.8:9000/imageproxy/https%3A%2F%2Fstation.example%2Flogo.png/image.png"
        )
    }

    func testUnescapedSpaceStillGetsEncoded() {
        // Plain (unescaped) paths must still be made URL-safe.
        XCTAssertEqual(resolve("plugins/Some Plugin/icon.png"),
                       "http://192.168.1.8:9000/plugins/Some%20Plugin/icon.png")
    }

    func testMalformedEscapeDoesNotTrapAndStillResolves() {
        // A stray '%' (not a valid escape) must not crash the
        // percentEncodedPath setter — falls back to plain path encoding.
        XCTAssertEqual(resolve("html/100% mix.png"),
                       "http://192.168.1.8:9000/html/100%25%20mix.png")
    }
}
