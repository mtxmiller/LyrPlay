// File: SlimProtoServPacketTests.swift
// serv packet sync-group parsing (bd LMS_StreamTest-433.4.2).
// Real LMS layout (Commands.pm:312): pack 'NA10' = 4-byte IP + 10 ASCII
// digits when synced, pack 'N' = bare 4-byte IP when not.
import Foundation
import Testing
@testable import LMS_StreamTest

struct SlimProtoServPacketTests {

    private let ip = Data([192, 168, 1, 8])

    @Test func parsesTenDigitGroupAfterIP() {
        let payload = ip + Data("1234567890".utf8)
        #expect(SlimProtoCoordinator.syncGroup(fromServPayload: payload) == "1234567890")
    }

    @Test func bareIPMeansNoGroup() {
        #expect(SlimProtoCoordinator.syncGroup(fromServPayload: ip) == nil)
    }

    @Test func allZeroGroupMeansUnsetPref() {
        // Server sends sprintf('%010d', pref || 0) — all zeros is "no group".
        let payload = ip + Data("0000000000".utf8)
        #expect(SlimProtoCoordinator.syncGroup(fromServPayload: payload) == nil)
    }

    @Test func nonDigitGroupRejected() {
        let payload = ip + Data("12345abcde".utf8)
        #expect(SlimProtoCoordinator.syncGroup(fromServPayload: payload) == nil)
    }

    @Test func oldEighteenByteAssumptionDoesNotResurface() {
        // A real 14-byte NA10 frame must parse; the old parser demanded >= 18
        // bytes and read bytes 8..<18, so it returned nothing for this frame.
        let payload = ip + Data("9876543210".utf8)
        #expect(payload.count == 14)
        #expect(SlimProtoCoordinator.syncGroup(fromServPayload: payload) == "9876543210")
    }
}
