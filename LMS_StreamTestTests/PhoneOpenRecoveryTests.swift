// File: PhoneOpenRecoveryTests.swift
// The silent app-open recovery runs only when the user opens LyrPlay on the
// phone. Device log 2026-10-25 (iOS 1.7.9 (22)): a CarPlay launch with the phone
// in a pocket ran it (the app-wide foreground event fires for the first scene,
// CarPlay's), and a CarPlay Resume 3s later was skipped because the server had
// "started a stream recently": the stream of that silent jump, already paused.
import Foundation
import Testing
import UIKit
@testable import LMS_StreamTest

struct PhoneOpenPolicyTests {
    @Test func phoneWindowComingForwardAloneIsAPhoneOpen() {
        #expect(PhoneOpenPolicy.isPhoneOpen(sceneRole: .windowApplication, anotherSceneInForeground: false))
    }

    @Test func carPlayComingForwardIsNot() {
        #expect(!PhoneOpenPolicy.isPhoneOpen(sceneRole: .carTemplateApplication, anotherSceneInForeground: false))
    }

    @Test func unlockingThePhoneWhileCarPlayShowsIsNot() {
        // The app never left the foreground, and app-open recovery in the car
        // can jump and play over the user's pause.
        #expect(!PhoneOpenPolicy.isPhoneOpen(sceneRole: .windowApplication, anotherSceneInForeground: true))
    }

    @Test func coldLaunchCountsOnlyWithThePhoneScreenUpAndNothingElse() {
        #expect(PhoneOpenPolicy.isColdPhoneOpen(phoneSceneInForeground: true, anotherSceneInForeground: false))
        // CarPlay launched the process and connected the window in the background.
        #expect(!PhoneOpenPolicy.isColdPhoneOpen(phoneSceneInForeground: false, anotherSceneInForeground: true))
        #expect(!PhoneOpenPolicy.isColdPhoneOpen(phoneSceneInForeground: false, anotherSceneInForeground: false))
        // First opened on the phone while CarPlay shows.
        #expect(!PhoneOpenPolicy.isColdPhoneOpen(phoneSceneInForeground: true, anotherSceneInForeground: true))
    }

    @Test func foregroundStates() {
        #expect(PhoneOpenPolicy.isForeground(.foregroundActive))
        #expect(PhoneOpenPolicy.isForeground(.foregroundInactive))
        #expect(!PhoneOpenPolicy.isForeground(.background))
        #expect(!PhoneOpenPolicy.isForeground(.unattached))
    }
}

struct SilentJumpStreamTests {
    private let sent = Date(timeIntervalSince1970: 1_000_000)

    @Test func streamRightAfterOurSilentJumpIsOurs() {
        // Log: jump sent 13:03:34.609, strm s 13:03:34.825.
        #expect(SlimProtoCoordinator.streamStartIsOurSilentJump(started: sent.addingTimeInterval(0.2),
                                                                silentJumpSentAt: sent))
    }

    @Test func noSilentJumpMeansLMSStartedIt() {
        #expect(!SlimProtoCoordinator.streamStartIsOurSilentJump(started: sent, silentJumpSentAt: nil))
    }

    @Test func streamBeforeTheJumpOrLongAfterIsNotOurs() {
        #expect(!SlimProtoCoordinator.streamStartIsOurSilentJump(started: sent.addingTimeInterval(-1),
                                                                 silentJumpSentAt: sent))
        #expect(!SlimProtoCoordinator.streamStartIsOurSilentJump(started: sent.addingTimeInterval(6),
                                                                 silentJumpSentAt: sent))
    }
}
