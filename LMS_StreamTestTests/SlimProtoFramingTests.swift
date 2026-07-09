import XCTest
@testable import LMS_StreamTest

/// bd LMS_StreamTest-433.1.3: an invalid (over-cap) frame length must not
/// desync the framing state machine. The bogus frame's payload has to be
/// consumed from the TCP stream before the next 2-byte header is read —
/// re-reading a header immediately would parse payload bytes as headers,
/// cascading garbage lengths until the connection dies.
final class SlimProtoFramingTests: XCTestCase {

    private func header(_ length: UInt16) -> Data {
        Data([UInt8(length >> 8), UInt8(length & 0xFF)])
    }

    func testValidLengthReadsMessage() {
        XCTAssertEqual(
            SlimProtoFraming.action(forHeader: header(28)),
            .readMessage(length: 28)
        )
    }

    func testZeroLengthReadsNextHeader() {
        XCTAssertEqual(
            SlimProtoFraming.action(forHeader: header(0)),
            .readNextHeader
        )
    }

    func testOversizedLengthDiscardsPayloadInsteadOfRereadingHeader() {
        XCTAssertEqual(
            SlimProtoFraming.action(forHeader: header(20000)),
            .discardPayload(length: 20000)
        )
        // Boundary: the cap itself is invalid, one below is valid
        XCTAssertEqual(
            SlimProtoFraming.action(forHeader: header(SlimProtoFraming.maxMessageLength)),
            .discardPayload(length: SlimProtoFraming.maxMessageLength)
        )
        XCTAssertEqual(
            SlimProtoFraming.action(forHeader: header(SlimProtoFraming.maxMessageLength - 1)),
            .readMessage(length: SlimProtoFraming.maxMessageLength - 1)
        )
    }

    /// Walk the state machine over a contiguous byte stream containing an
    /// oversized frame followed by a valid one: after discarding the bad
    /// frame's payload, the good frame must parse at the correct offset.
    func testOversizedFrameFollowedByValidFrameStaysAligned() {
        let goodPayload = Data("strm".utf8) + Data(repeating: 0x01, count: 24)
        var stream = Data()
        stream.append(header(12000))
        stream.append(Data(repeating: 0xAB, count: 12000))
        stream.append(header(UInt16(goodPayload.count)))
        stream.append(goodPayload)

        var offset = 0
        guard case .discardPayload(let badLength) =
                SlimProtoFraming.action(forHeader: stream.subdata(in: offset..<offset + 2)) else {
            return XCTFail("oversized frame should be discarded, not re-read as header")
        }
        offset += 2 + Int(badLength)

        guard case .readMessage(let goodLength) =
                SlimProtoFraming.action(forHeader: stream.subdata(in: offset..<offset + 2)) else {
            return XCTFail("valid frame after discard should parse as a message")
        }
        offset += 2
        XCTAssertEqual(
            stream.subdata(in: offset..<offset + Int(goodLength)),
            goodPayload,
            "payload after realignment must be the valid frame's bytes"
        )
    }
}
