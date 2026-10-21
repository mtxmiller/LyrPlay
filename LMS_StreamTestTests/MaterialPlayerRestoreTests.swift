import XCTest
@testable import LMS_StreamTest

/// Material switches to its default player when the player list refreshes
/// after a reconnect (store.js, Material #387). LyrPlay puts itself back only
/// when that switch looks like Material's doing (bd vdb6).
final class MaterialPlayerRestoreTests: XCTestCase {
    private let ours = "aa:bb:cc:dd:ee:ff"
    private let kitchen = "00:11:22:33:44:55"

    func testSwitchAwayRightAfterReconnectIsRestored() {
        XCTAssertTrue(MaterialPlayerRestore.shouldRestore(previousID: ours, newID: kitchen, localID: ours,
                                                          reconnectedAgo: 3, playing: true))
    }

    func testCaseOfTheIDDoesNotMatter() {
        XCTAssertTrue(MaterialPlayerRestore.shouldRestore(previousID: ours.uppercased(), newID: kitchen, localID: ours,
                                                          reconnectedAgo: 3, playing: false))
    }

    func testUserSwitchLaterIsLeftAlone() {
        XCTAssertFalse(MaterialPlayerRestore.shouldRestore(previousID: ours, newID: kitchen, localID: ours,
                                                           reconnectedAgo: 45, playing: true))
    }

    func testSwitchToOurselvesNeedsNothing() {
        XCTAssertFalse(MaterialPlayerRestore.shouldRestore(previousID: kitchen, newID: ours, localID: ours,
                                                           reconnectedAgo: 3, playing: true))
    }

    func testAnotherPlayerWasSelectedBeforeTheDrop() {
        // The user was looking at the kitchen: Material moving to its default is not ours to undo.
        XCTAssertFalse(MaterialPlayerRestore.shouldRestore(previousID: kitchen, newID: "66:77:88:99:aa:bb", localID: ours,
                                                           reconnectedAgo: 3, playing: true))
    }

    func testAfterAReloadOnlyWhilePlaying() {
        XCTAssertTrue(MaterialPlayerRestore.shouldRestore(previousID: nil, newID: kitchen, localID: ours,
                                                          reconnectedAgo: 3, playing: true))
        XCTAssertFalse(MaterialPlayerRestore.shouldRestore(previousID: nil, newID: kitchen, localID: ours,
                                                           reconnectedAgo: 3, playing: false))
    }

    func testNeverConnectedOrUnknownPlayer() {
        XCTAssertFalse(MaterialPlayerRestore.shouldRestore(previousID: ours, newID: kitchen, localID: ours,
                                                           reconnectedAgo: nil, playing: true))
        XCTAssertFalse(MaterialPlayerRestore.shouldRestore(previousID: ours, newID: nil, localID: ours,
                                                           reconnectedAgo: 3, playing: true))
        XCTAssertFalse(MaterialPlayerRestore.shouldRestore(previousID: ours, newID: kitchen, localID: "",
                                                           reconnectedAgo: 3, playing: true))
    }
}
