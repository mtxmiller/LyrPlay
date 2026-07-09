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
}
