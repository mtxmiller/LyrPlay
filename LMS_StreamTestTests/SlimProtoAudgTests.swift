// File: SlimProtoAudgTests.swift
// audg gain → BASS volume mapping (bd LMS_StreamTest-433.4.4).
// BASS has one volume for both channels; the app maps (L, R) via max so a
// server-side balance setting never silently mutes or halves playback.
import Testing
@testable import LMS_StreamTest

struct SlimProtoAudgTests {

    private let unity: UInt32 = 65536  // 16.16 fixed point

    @Test func fixedVolumeModeIsUnity() {
        // dvc=0: player runs at fixed volume regardless of gains (squeezelite parity)
        #expect(SlimProtoCommandHandler.volume(fromAudgDVC: 0, gainL: 0, gainR: 0) == 1.0)
    }

    @Test func equalGainsMapLinearly() {
        let half = SlimProtoCommandHandler.volume(fromAudgDVC: 1, gainL: unity / 2, gainR: unity / 2)
        #expect(abs(half - 0.5) < 0.001)
    }

    @Test func hardLeftBalanceKeepsLouderChannelLevel() {
        // Right gain dropped to 0 (balance hard left) must not mute playback
        #expect(SlimProtoCommandHandler.volume(fromAudgDVC: 1, gainL: unity, gainR: 0) == 1.0)
    }

    @Test func hardRightBalanceKeepsLouderChannelLevel() {
        // Right channel gain was previously ignored entirely — this was silence
        #expect(SlimProtoCommandHandler.volume(fromAudgDVC: 1, gainL: 0, gainR: unity) == 1.0)
    }

    @Test func overUnityGainClamped() {
        #expect(SlimProtoCommandHandler.volume(fromAudgDVC: 1, gainL: unity * 2, gainR: 0) == 1.0)
    }
}
