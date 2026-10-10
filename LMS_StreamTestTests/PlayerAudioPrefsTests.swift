//
//  PlayerAudioPrefsTests.swift
//  LMS_StreamTestTests
//
//  bd x19i — Settings reads/writes Fixed Output + ReplayGain as LMS player prefs.
//

import Foundation
import Testing
@testable import LMS_StreamTest

private final class MockRunner: SlimProtoJSONRPCRunner {
    var sent: [[Any]] = []
    var responses: [String: [String: Any]] = [:]   // keyed by pref name
    var failWrites = false

    func sendJSONRPCCommandDirect(_ jsonRPC: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let params = jsonRPC["params"] as? [Any] ?? []
        let command = params.count > 1 ? (params[1] as? [Any] ?? []) : []
        sent.append(command)
        let name = command.count > 1 ? (command[1] as? String ?? "") : ""
        let isQuery = (command.last as? String) == "?"
        if isQuery {
            completion(responses[name] ?? [:])
        } else {
            completion(failWrites ? [:] : ["result": [:]])
        }
    }
}

/// Lets the model's main-queue hop run.
private func drainMain() async {
    await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
}

struct PlayerAudioPrefsTests {

    @Test func parsesStringPrefValue() {
        // Verified against LMS 9: {"result":{"_p2":"3"}}
        #expect(PlayerAudioPrefsModel.prefValue(from: ["result": ["_p2": "3"]]) == 3)
        #expect(PlayerAudioPrefsModel.prefValue(from: ["result": ["_p2": 1]]) == 1)
        #expect(PlayerAudioPrefsModel.prefValue(from: [:]) == nil)
        #expect(PlayerAudioPrefsModel.prefValue(from: ["result": ["_p2": ""]]) == nil)
    }

    @Test func replayGainModesMatchLMSValues() {
        #expect(ReplayGainMode.allCases.map(\.rawValue) == [0, 1, 2, 3])
    }

    @Test @MainActor func loadMapsServerPrefs() async {
        let runner = MockRunner()
        runner.responses["digitalVolumeControl"] = ["result": ["_p2": "0"]]
        runner.responses["replayGainMode"] = ["result": ["_p2": "2"]]
        let model = PlayerAudioPrefsModel(runner: runner, playerID: "aa:bb:cc:dd:ee:ff")

        model.load()
        await drainMain()

        #expect(model.fixedOutput == true)          // dvc 0 = fixed at 100%
        #expect(model.replayGainMode == .album)
    }

    @Test @MainActor func loadLeavesUnknownWhenServerSilent() async {
        let model = PlayerAudioPrefsModel(runner: MockRunner(), playerID: "aa:bb:cc:dd:ee:ff")
        model.load()
        await drainMain()
        #expect(model.fixedOutput == nil)
        #expect(model.replayGainMode == nil)
    }

    @Test @MainActor func setReplayGainWritesPlayerPref() async {
        let runner = MockRunner()
        let model = PlayerAudioPrefsModel(runner: runner, playerID: "aa:bb:cc:dd:ee:ff")

        model.setReplayGainMode(.smart)
        await drainMain()

        #expect(model.replayGainMode == .smart)
        let last = runner.sent.last ?? []
        #expect(last.count == 3)
        #expect(last[0] as? String == "playerpref")
        #expect(last[1] as? String == "replayGainMode")
        #expect(last[2] as? Int == 3)
    }

    @Test @MainActor func failedWriteRevertsReplayGain() async {
        let runner = MockRunner()
        runner.responses["replayGainMode"] = ["result": ["_p2": "1"]]
        let model = PlayerAudioPrefsModel(runner: runner, playerID: "aa:bb:cc:dd:ee:ff")
        model.load()
        await drainMain()

        runner.failWrites = true
        model.setReplayGainMode(.off)
        await drainMain()

        #expect(model.replayGainMode == .track)
    }

    @Test @MainActor func noPlayerIDSendsNothing() async {
        let runner = MockRunner()
        let model = PlayerAudioPrefsModel(runner: runner, playerID: "")
        model.load()
        await drainMain()
        #expect(runner.sent.isEmpty)
    }
}
