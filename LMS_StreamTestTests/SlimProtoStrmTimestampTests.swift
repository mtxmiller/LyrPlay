import XCTest
@testable import LMS_StreamTest

/// bd LMS_StreamTest-433.1.5: the server timestamp echoed in STAT for a
/// strm 't' lives in the replay_gain field — bytes 14..<18 of the
/// 'aaaaaaaCCCaCCCNnN' layout (squeezelite slimproto.c:
/// sendSTAT("STMt", strm->replay_gain)). The old code read bytes 20..<24,
/// which is the server_ip field.
final class SlimProtoStrmTimestampTests: XCTestCase {

    /// Minimal 24-byte strm payload with the two N fields set explicitly.
    private func strmPayload(replayGain: UInt32, serverIP: UInt32) -> Data {
        var payload = Data(count: 24)
        payload[0] = Character("t").asciiValue!
        withUnsafeBytes(of: replayGain.bigEndian) { payload.replaceSubrange(14..<18, with: $0) }
        withUnsafeBytes(of: serverIP.bigEndian) { payload.replaceSubrange(20..<24, with: $0) }
        return payload
    }

    func testTimestampReadFromReplayGainField() {
        let payload = strmPayload(replayGain: 0xDEAD_BEEF, serverIP: 0)
        XCTAssertEqual(
            SlimProtoCommandHandler.serverTimestamp(fromStrmPayload: payload),
            0xDEAD_BEEF
        )
    }

    func testTimestampNotReadFromServerIPField() {
        // The old bug read server_ip (bytes 20..<24) — a nonzero server_ip
        // with a zero replay_gain must yield 0, not the IP bits.
        let payload = strmPayload(replayGain: 0, serverIP: 0xC0A8_0108)
        XCTAssertEqual(
            SlimProtoCommandHandler.serverTimestamp(fromStrmPayload: payload),
            0
        )
    }

    func testShortPayloadYieldsZero() {
        XCTAssertEqual(
            SlimProtoCommandHandler.serverTimestamp(fromStrmPayload: Data(count: 10)),
            0
        )
    }
}
