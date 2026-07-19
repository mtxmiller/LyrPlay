import XCTest
@testable import LMS_StreamTest

/// Parser tests for Material's native bridge MATERIAL-PLAYER messages
/// (GH#75). Wire shape from lms-material store.js `storeCurrentPlayer`:
/// "MATERIAL-PLAYER\nID <mac>\nNAME <name>\nIP <ip>" posted to the
/// mskNative WKScriptMessageHandler when loaded with ?nativePlayer=3.
final class MaterialPlayerMessageTests: XCTestCase {

    func testParseFullMessage() {
        let msg = MaterialPlayerMessage.parse("MATERIAL-PLAYER\nID aa:bb:cc:dd:ee:ff\nNAME Kitchen\nIP 192.168.1.50:34657")
        XCTAssertEqual(msg?.id, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(msg?.name, "Kitchen")
        XCTAssertEqual(msg?.ip, "192.168.1.50:34657")
    }

    func testParseMissingNameAndIP() {
        let msg = MaterialPlayerMessage.parse("MATERIAL-PLAYER\nID aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(msg?.id, "aa:bb:cc:dd:ee:ff")
        XCTAssertNil(msg?.name)
        XCTAssertNil(msg?.ip)
    }

    func testParsePlayerNameWithSpaces() {
        let msg = MaterialPlayerMessage.parse("MATERIAL-PLAYER\nID aa:bb:cc:dd:ee:ff\nNAME Living Room Amp\nIP 10.0.0.2")
        XCTAssertEqual(msg?.name, "Living Room Amp")
    }

    func testParseRejectsWrongPrefix() {
        XCTAssertNil(MaterialPlayerMessage.parse("MATERIAL-STATUS\nID aa:bb:cc:dd:ee:ff"))
    }

    func testParseRejectsEmptyString() {
        XCTAssertNil(MaterialPlayerMessage.parse(""))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(MaterialPlayerMessage.parse("not a material message at all"))
    }

    func testParseRejectsMissingID() {
        XCTAssertNil(MaterialPlayerMessage.parse("MATERIAL-PLAYER\nNAME Kitchen\nIP 10.0.0.2"))
    }

    func testParseRejectsEmptyID() {
        XCTAssertNil(MaterialPlayerMessage.parse("MATERIAL-PLAYER\nID \nNAME Kitchen"))
    }

    func testParseIgnoresUnknownExtraLines() {
        let msg = MaterialPlayerMessage.parse("MATERIAL-PLAYER\nID aa:bb:cc:dd:ee:ff\nNAME Kitchen\nFUTURE somefield\nIP 10.0.0.2")
        XCTAssertEqual(msg?.id, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(msg?.ip, "10.0.0.2")
    }
}
