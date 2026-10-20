// File: ReconnectHeloTests.swift
// Riding out a network drop: the HELO's reconnect bit keeps LMS's session
// (Squeezebox.pm reconnect), track events held offline reach it afterwards,
// and a decode that ended offline is told apart from a cut download.
import Testing
@testable import LMS_StreamTest

struct ReconnectHeloDecisionTests {
    private func decide(enabled: Bool = true, sameServer: Bool = true,
                        trigger: RecoveryTrigger = .networkRestored, state: String = "Playing",
                        stalled: Bool = false, hold: Bool = false) -> Bool {
        SlimProtoCoordinator.heloShouldReconnect(enabled: enabled, sameServerAsSession: sameServer,
                                                 trigger: trigger, playerState: state,
                                                 stalled: stalled, outageHold: hold)
    }

    @Test func reconnectsWhilePlayingThroughADrop() {
        #expect(decide())
        #expect(decide(trigger: .none))
    }

    @Test func reconnectsWhilePausedStalledOrHeld() {
        #expect(decide(state: "Paused"))
        #expect(decide(state: "Stopped", stalled: true))
        #expect(decide(state: "No Stream", hold: true))
    }

    @Test func freshWithNothingToKeep() {
        #expect(!decide(state: "Stopped"))
        #expect(!decide(state: "No Stream"))
    }

    @Test func freshForTheFirstConnectOrAnotherServer() {
        // sessionServer is nil at the first connect, or a failover changed the server.
        #expect(!decide(sameServer: false))
    }

    @Test func freshForAppOpenAndLockScreenRecoveries() {
        #expect(!decide(trigger: .appOpen))
        #expect(!decide(trigger: .lockScreen))
    }

    @Test func freshWhenSwitchedOff() {
        #expect(!decide(enabled: false))
    }
}

struct HeloReconnectFieldTests {
    @Test func reconnectSetsSqueezelitesBit() {
        #expect(SlimProtoHeloReconnect(isReconnect: true, bytesReceived: 5).wlanChannels == 0x4000)
        #expect(SlimProtoHeloReconnect.fresh.wlanChannels == 0)
        #expect(SlimProtoHeloReconnect.fresh.bytesReceived == 0)
    }
}

struct OfflineEventQueueTests {
    @Test func keepsTrackEventsInOrderForAReconnect() {
        var q = SlimProtoOfflineEvents()
        let held = ["STMs", "STMd", "STMu"].map { q.hold($0) }
        #expect(held == [true, true, true])
        let first = q.take(afterReconnect: true)
        let second = q.take(afterReconnect: true)
        #expect(first == ["STMs", "STMd", "STMu"])
        #expect(second.isEmpty)
    }

    @Test func dropsThemAfterAFreshHelo() {
        var q = SlimProtoOfflineEvents()
        _ = q.hold("STMd")
        let taken = q.take(afterReconnect: false)
        #expect(taken.isEmpty)
        #expect(q.pending.isEmpty)
    }

    @Test func ignoresHeartbeatsAndOtherStatus() {
        var q = SlimProtoOfflineEvents()
        let held = [q.hold("STMt"), q.hold("STMp")]
        #expect(held == [false, false])
        #expect(q.pending.isEmpty)
    }

    @Test func resendsAnUnansweredStmdAfterTheDrop() {
        var q = SlimProtoOfflineEvents()
        q.sent("STMd")
        q.sent("STMt")
        q.connectionLost()
        _ = q.hold("STMu")
        #expect(q.take(afterReconnect: true) == ["STMd", "STMu"])
    }

    @Test func aServerFrameConfirmsTheStmd() {
        var q = SlimProtoOfflineEvents()
        q.sent("STMd")
        q.serverFrameArrived()
        q.connectionLost()
        _ = q.hold("STMu")
        #expect(q.take(afterReconnect: true) == ["STMu"])
    }

    @Test func unansweredStmdIsDroppedAfterAFreshHelo() {
        var q = SlimProtoOfflineEvents()
        q.sent("STMd")
        q.connectionLost()
        #expect(q.take(afterReconnect: false).isEmpty)
        #expect(q.unconfirmed.isEmpty)
    }

    @Test func boundedKeepingTheNewest() {
        var q = SlimProtoOfflineEvents()
        for _ in 0..<SlimProtoOfflineEvents.limit { _ = q.hold("STMs") }
        _ = q.hold("STMd")
        #expect(q.pending.count == SlimProtoOfflineEvents.limit)
        #expect(q.pending.last == "STMd")
    }
}

struct HeldDecodeEndTests {
    private func ended(ahead: Bool = false, decoded: Double? = nil, trackTime: Double = 0,
                       buffered: Double = 0, current: Double = 260, next: Double = 180) -> Bool {
        SlimProtoCoordinator.heldDecodeEndWasTrackEnd(decodingAhead: ahead, decodedEndSeconds: decoded,
                                                      trackTime: trackTime, bufferedSeconds: buffered,
                                                      currentDuration: current, nextDuration: next)
    }

    // Rig run 2026-10-18 (O4 before the kill): 160.7s played + 29.0s buffered of a 260s track.
    @Test func currentTrackCutShort() {
        #expect(!ended(trackTime: 160.7, buffered: 29.0))
    }

    @Test func currentTrackReallyEnded() {
        #expect(ended(trackTime: 231.0, buffered: 28.5))
        #expect(ended(trackTime: 259.0, buffered: 0))   // already drained
    }

    @Test func nextTrackComparesItsOwnDecodedSeconds() {
        #expect(ended(ahead: true, decoded: 179.5))
        #expect(!ended(ahead: true, decoded: 40))
    }

    @Test func unknownDurationCountsAsAnEnd() {
        // Radio / no duration: keep the old behaviour (STMd).
        #expect(ended(trackTime: 10, current: 0))
        #expect(ended(ahead: true, decoded: 5, next: 0))
        #expect(ended(ahead: true, decoded: nil))
    }
}

struct ForgottenRestartTests {
    private let target = SlimProtoCoordinator.RecoveryTarget(index: 0, position: 59.0)

    // Rig O5 2026-10-18: LMS forgot us after 320s and restarted at ~10s; the audio had stopped near 59s.
    @Test func jumpsWhenLMSRestartedFarBehind() {
        #expect(SlimProtoCoordinator.forgottenRestartNeedsJump(serverIndex: 0, serverTime: 12.0, mode: "play", target: target))
    }

    @Test func leavesARestartAtTheRightPlace() {
        #expect(!SlimProtoCoordinator.forgottenRestartNeedsJump(serverIndex: 0, serverTime: 61.0, mode: "play", target: target))
    }

    @Test func afterDownloadedCopiesAnyTrackIsCorrected() {
        // Offline the copies moved us on to track 2; the forgotten LMS restarts track 0.
        let lifeboatTarget = SlimProtoCoordinator.RecoveryTarget(index: 2, position: 23)
        #expect(SlimProtoCoordinator.forgottenRestartNeedsJump(serverIndex: 0, serverTime: 29.4, mode: "play",
                                                               target: lifeboatTarget, anyTrack: true))
    }

    @Test func leavesAnotherTrackOrAStoppedPlayer() {
        #expect(!SlimProtoCoordinator.forgottenRestartNeedsJump(serverIndex: 1, serverTime: 3.0, mode: "play", target: target))
        #expect(!SlimProtoCoordinator.forgottenRestartNeedsJump(serverIndex: 0, serverTime: 0, mode: "stop", target: target))
        #expect(!SlimProtoCoordinator.forgottenRestartNeedsJump(serverIndex: nil, serverTime: 0, mode: "play", target: target))
    }
}

// Another controller acted while we were offline: its strm never reached us,
// and with the reconnect bit LMS won't restart us, so we must look.
struct KeptSessionCheckTests {
    @Test func keptWhenLMSStillPlaysOurTrack() {
        #expect(SlimProtoCoordinator.keptSessionCheck(serverMode: "play", serverIndex: 3, localIndex: 3) == .kept)
        #expect(SlimProtoCoordinator.keptSessionCheck(serverMode: "play", serverIndex: nil, localIndex: 3) == .kept)
    }

    @Test func followsAPauseOrStopMadeMeanwhile() {
        #expect(SlimProtoCoordinator.keptSessionCheck(serverMode: "pause", serverIndex: 3, localIndex: 3) == .pauseLocally)
        #expect(SlimProtoCoordinator.keptSessionCheck(serverMode: "stop", serverIndex: 3, localIndex: 3) == .stopLocally)
    }

    @Test func followsATrackChangeMadeMeanwhile() {
        #expect(SlimProtoCoordinator.keptSessionCheck(serverMode: "play", serverIndex: 5, localIndex: 3) == .followServer)
    }
}

// Where the reconnect puts LMS when the copies or the buffer ran out at the
// very end of a track (rig O13/O21, 2026-10-19).
struct SettledJumpTargetTests {
    private func settle(index: Int = 8, position: Double, duration: Double? = 161, tracks: Int? = 9,
                        repeatMode: Int? = 0) -> SlimProtoCoordinator.RecoveryTarget? {
        SlimProtoCoordinator.settledJumpTarget(index: index, position: position, duration: duration,
                                               playlistTracks: tracks, repeatMode: repeatMode)
    }

    @Test func midTrackIsLeftAlone() {
        #expect(settle(position: 100) == SlimProtoCoordinator.RecoveryTarget(index: 8, position: 100))
        #expect(settle(position: 100, duration: nil) == SlimProtoCoordinator.RecoveryTarget(index: 8, position: 100))
    }

    @Test func endOfATrackGoesToTheNextOne() {
        #expect(settle(index: 3, position: 160.5) == SlimProtoCoordinator.RecoveryTarget(index: 4, position: 0.5))
    }

    @Test func endOfThePlaylistStopsUnlessRepeating() {
        #expect(settle(position: 161.1) == nil)
        #expect(settle(position: 161.1, repeatMode: 2) == SlimProtoCoordinator.RecoveryTarget(index: 0, position: 0.5))
        #expect(settle(position: 161.1, repeatMode: 1) == SlimProtoCoordinator.RecoveryTarget(index: 8, position: 0.5))
    }
}

struct HeldDecodeEndDecodedLengthTests {
    // Rig O22: the copy decoded all 260s, the tracker had stopped at 256.6.
    @Test func decodedUpToTheDurationIsTheEnd() {
        #expect(SlimProtoCoordinator.heldDecodeEndWasTrackEnd(decodingAhead: false, decodedEndSeconds: 260.0,
                                                              trackTime: 256.6, bufferedSeconds: 0,
                                                              currentDuration: 260, nextDuration: 172))
        #expect(!SlimProtoCoordinator.heldDecodeEndWasTrackEnd(decodingAhead: false, decodedEndSeconds: 190.0,
                                                               trackTime: 160.7, bufferedSeconds: 29.0,
                                                               currentDuration: 260, nextDuration: 172))
    }
}

struct LifeboatStreamFormatTests {
    @Test func strictMatchOnlyForLosslessStreams() {
        #expect(SlimProtoCoordinator.streamFormatIsLossless("FLAC"))
        #expect(SlimProtoCoordinator.streamFormatIsLossless("WAV"))
        #expect(SlimProtoCoordinator.streamFormatIsLossless("ALAC"))
        #expect(!SlimProtoCoordinator.streamFormatIsLossless("Opus"))
        #expect(!SlimProtoCoordinator.streamFormatIsLossless("MP3"))
        #expect(!SlimProtoCoordinator.streamFormatIsLossless("AAC"))
        #expect(!SlimProtoCoordinator.streamFormatIsLossless("OGG"))
    }
}
