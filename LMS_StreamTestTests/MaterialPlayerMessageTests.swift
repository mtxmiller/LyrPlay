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

    func testPlayerParserRejectsConnectionStatus() {
        XCTAssertNil(MaterialPlayerMessage.parse("MATERIAL-CONNETIONSTATUS\nCONNECTED false"))
    }
}

/// Material's link report (bd toz7), lms-material server.js:
/// `emitNative("MATERIAL-CONNETIONSTATUS\nCONNECTED " + connected, ...)`
/// when loaded with ?nativeConnectionStatus=w. Material's own spelling.
final class MaterialConnectionMessageTests: XCTestCase {

    func testParseConnected() {
        XCTAssertEqual(MaterialConnectionMessage.parse("MATERIAL-CONNETIONSTATUS\nCONNECTED true"),
                       MaterialConnectionMessage(connected: true))
    }

    func testParseLost() {
        XCTAssertEqual(MaterialConnectionMessage.parse("MATERIAL-CONNETIONSTATUS\nCONNECTED false"),
                       MaterialConnectionMessage(connected: false))
    }

    func testParseRejectsPlayerMessage() {
        XCTAssertNil(MaterialConnectionMessage.parse("MATERIAL-PLAYER\nID aa:bb:cc:dd:ee:ff"))
    }

    func testParseRejectsMissingOrOddValue() {
        XCTAssertNil(MaterialConnectionMessage.parse("MATERIAL-CONNETIONSTATUS"))
        XCTAssertNil(MaterialConnectionMessage.parse("MATERIAL-CONNETIONSTATUS\nCONNECTED maybe"))
    }
}

/// The restart script only acts on Material's own objects (MaterialReconnect).
final class MaterialReconnectTests: XCTestCase {

    func testScriptCarriesTheForceFlagAndMaterialsOwnRestart() {
        let forced = MaterialReconnect.script(force: true)
        let gentle = MaterialReconnect.script(force: false)
        XCTAssertTrue(forced.hasSuffix("})(true);"))
        XCTAssertTrue(gentle.hasSuffix("})(false);"))
        for script in [forced, gentle] {
            XCTAssertTrue(script.contains("clearListeners()"))
            XCTAssertTrue(script.contains("disconnect()"))
            XCTAssertTrue(script.contains("connectToCometD()"))
            XCTAssertTrue(script.contains("typeof lmsIsConnected === 'undefined'"))
        }
    }
}
