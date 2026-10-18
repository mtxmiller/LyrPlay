// File: SlimProtoConnectChurnTests.swift
// Several triggers call connect() within a second at launch and foreground.
// Each used to tear down the socket the previous one had just opened, so
// app-open recovery started on a connection that was then replaced
// (simulator log 2026-10-16: three connects in 0.6s, recovery never ran).
import Testing
@testable import LMS_StreamTest

struct SlimProtoConnectChurnTests {
    @Test func keepsASocketStillConnectingToTheSameServer() {
        #expect(SlimProtoClient.shouldKeepExistingSocket(
            sameServer: true, isConnecting: true, isConnected: false, connectedFor: nil))
    }

    @Test func keepsAFreshSocketToTheSameServer() {
        #expect(SlimProtoClient.shouldKeepExistingSocket(
            sameServer: true, isConnecting: false, isConnected: true, connectedFor: 0.4))
    }

    @Test func replacesAnOldSocketThatMayBeAZombieAfterSuspension() {
        #expect(!SlimProtoClient.shouldKeepExistingSocket(
            sameServer: true, isConnecting: false, isConnected: true,
            connectedFor: SlimProtoClient.freshConnectionWindow + 1))
    }

    @Test func replacesTheSocketWhenTheServerChanged() {
        // Failover or a settings change points at another server.
        #expect(!SlimProtoClient.shouldKeepExistingSocket(
            sameServer: false, isConnecting: true, isConnected: false, connectedFor: nil))
        #expect(!SlimProtoClient.shouldKeepExistingSocket(
            sameServer: false, isConnecting: false, isConnected: true, connectedFor: 0.4))
    }

    @Test func connectsWhenThereIsNoSocket() {
        #expect(!SlimProtoClient.shouldKeepExistingSocket(
            sameServer: true, isConnecting: false, isConnected: false, connectedFor: nil))
    }

    // A socket opened just before the network changed can't be kept: in the car,
    // one opened on home Wi-Fi is dead once the phone moves to cellular.
    @Test func lossOrInterfaceChangeInvalidatesTheSocket() {
        typealias M = SlimProtoConnectionManager
        #expect(M.pathInvalidatesSocket(wasAvailable: true, isAvailable: false, previous: .wifi, current: .unavailable))
        #expect(M.pathInvalidatesSocket(wasAvailable: true, isAvailable: true, previous: .wifi, current: .cellular))
        #expect(!M.pathInvalidatesSocket(wasAvailable: true, isAvailable: true, previous: .wifi, current: .wifi))
    }

    @Test func theFirstPathUpdateAtLaunchDoesNot() {
        // At launch the monitor starts "unavailable" and reports the real path
        // once; that must not undo the launch churn fix.
        #expect(!SlimProtoConnectionManager.pathInvalidatesSocket(
            wasAvailable: false, isAvailable: true, previous: .unknown, current: .wifi))
    }
}
