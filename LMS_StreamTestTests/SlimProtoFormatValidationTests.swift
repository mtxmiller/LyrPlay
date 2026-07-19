import XCTest
@testable import LMS_StreamTest

/// bd LMS_StreamTest-433.1.6: only strm 's' (start) carries a real format
/// byte — LMS hardcodes a filler ('m') into every other frame, and any
/// server/fork that packs a different byte must not be answered with a
/// decode-error STMn (LMS treats that as track failure). rejectsFormat is
/// the sole gate in processServerCommand before the STMn early-return, so
/// rejectsFormat == false for a 't' means the dispatch reaches the status
/// handler and answers STMt.
final class SlimProtoFormatValidationTests: XCTestCase {

    private func ascii(_ c: Character) -> UInt8 { c.asciiValue! }

    func testStatusRequestWithUnknownFormatByteIsNotRejected() {
        // The bead's scenario: strm 't' with format byte 0x00 must produce
        // STMt, not STMn — i.e. it must not trip format rejection.
        XCTAssertFalse(
            SlimProtoCommandHandler.rejectsFormat(streamCommand: ascii("t"), format: 0x00)
        )
    }

    func testNonStartCommandsIgnoreFormatByte() {
        for command: Character in ["t", "p", "u", "a", "q", "f"] {
            XCTAssertFalse(
                SlimProtoCommandHandler.rejectsFormat(streamCommand: ascii(command), format: 0x00),
                "strm '\(command)' must not consult the format byte"
            )
        }
    }

    func testStartCommandRejectsUnknownFormat() {
        XCTAssertTrue(
            SlimProtoCommandHandler.rejectsFormat(streamCommand: ascii("s"), format: 0x00)
        )
    }

    func testStartCommandAcceptsSupportedFormats() {
        for format: Character in ["a", "A", "m", "f", "p", "w", "o", "u"] {
            XCTAssertFalse(
                SlimProtoCommandHandler.rejectsFormat(streamCommand: ascii("s"), format: ascii(format)),
                "format '\(format)' should be accepted on 's'"
            )
        }
    }

    func testFormatNameMapping() {
        XCTAssertEqual(SlimProtoCommandHandler.formatName(forStrmFormatByte: ascii("f")), "FLAC")
        XCTAssertEqual(SlimProtoCommandHandler.formatName(forStrmFormatByte: ascii("a")), "AAC")
        XCTAssertNil(SlimProtoCommandHandler.formatName(forStrmFormatByte: 0x00))
    }
}
