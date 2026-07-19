// File: ConnectionManagerReconnectPolicyTests.swift
// Network-restore reconnection decision (bd LMS_StreamTest-433.3.1).
// The wedge: handleNetworkRestored only acted when state was exactly
// .networkUnavailable, so a network drop during an in-flight connect
// (.connecting/.reconnecting) left the app stuck until a socket timeout.
import Testing
@testable import LMS_StreamTest

struct ConnectionManagerReconnectPolicyTests {

    @Test func reconnectsFromAnyNonConnectedState() {
        let states: [SlimProtoConnectionManager.ConnectionState] = [
            .disconnected, .connecting, .reconnecting, .failed, .networkUnavailable
        ]
        for state in states {
            #expect(SlimProtoConnectionManager.shouldReconnectOnNetworkRestore(
                state: state, hasEverConnected: true),
                "network restore must reconnect from \(state)")
        }
    }

    @Test func doesNotReconnectWhenAlreadyConnected() {
        #expect(!SlimProtoConnectionManager.shouldReconnectOnNetworkRestore(
            state: .connected, hasEverConnected: true))
    }

    @Test func doesNotAutoConnectBeforeFirstEverConnection() {
        // Cold launch / unconfigured server: network coming up must not connect.
        #expect(!SlimProtoConnectionManager.shouldReconnectOnNetworkRestore(
            state: .disconnected, hasEverConnected: false))
    }
}
