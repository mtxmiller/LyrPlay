// File: PlayerAudioPrefs.swift
// Server-side per-player audio prefs shown in iOS Settings (bd x19i).
import Foundation
import os.log

/// LMS `replayGainMode` player pref (slimserver Slim/Player/ReplayGain.pm).
enum ReplayGainMode: Int, CaseIterable, Identifiable {
    case off = 0
    case track = 1
    case album = 2
    case smart = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track"
        case .album: return "Album"
        case .smart: return "Smart"
        }
    }
}

/// Reads and writes the LMS player prefs behind Fixed Output and ReplayGain.
/// The server owns these — Material edits the same prefs — so Settings loads
/// them on open and writes through JSON-RPC instead of trusting a local copy.
/// `nil` means not loaded yet (or the server didn't answer).
final class PlayerAudioPrefsModel: ObservableObject {
    @Published private(set) var fixedOutput: Bool?
    @Published private(set) var replayGainMode: ReplayGainMode?

    private weak var runner: SlimProtoJSONRPCRunner?
    private let playerID: String
    private let logger = OSLog(subsystem: "com.lmsstream", category: "PlayerAudioPrefs")

    init(runner: SlimProtoJSONRPCRunner?, playerID: String) {
        self.runner = runner
        self.playerID = playerID
    }

    func load() {
        queryPref("digitalVolumeControl") { [weak self] value in
            // digitalVolumeControl: 1 = LMS software volume, 0 = fixed at 100%
            self?.fixedOutput = value.map { $0 == 0 }
        }
        queryPref("replayGainMode") { [weak self] value in
            self?.replayGainMode = value.flatMap(ReplayGainMode.init(rawValue:))
        }
    }

    /// Records a Fixed Output change the caller already sent to the server
    /// (via `applyFixedOutputPolicy` / `restoreSoftwareVolumeControl`).
    func noteFixedOutputChanged(_ fixed: Bool) {
        fixedOutput = fixed
    }

    func setReplayGainMode(_ mode: ReplayGainMode) {
        let previous = replayGainMode
        replayGainMode = mode
        send(["playerpref", "replayGainMode", mode.rawValue]) { [weak self] response in
            // Empty response = request failed; show the server's value again.
            guard response.isEmpty, let self else { return }
            os_log(.error, log: self.logger, "❌ replayGainMode write failed — reverting UI")
            self.replayGainMode = previous
        }
    }

    /// Extracts a `playerpref <name> ?` answer: `{"result": {"_p2": "1"}}`.
    static func prefValue(from response: [String: Any]) -> Int? {
        guard let result = response["result"] as? [String: Any] else { return nil }
        if let n = result["_p2"] as? Int { return n }
        if let s = result["_p2"] as? String { return Int(s) }
        return nil
    }

    private func queryPref(_ name: String, completion: @escaping (Int?) -> Void) {
        send(["playerpref", name, "?"]) { response in
            completion(Self.prefValue(from: response))
        }
    }

    private func send(_ command: [Any], completion: @escaping ([String: Any]) -> Void) {
        guard let runner, !playerID.isEmpty else {
            completion([:])
            return
        }
        let request: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [playerID, command]
        ]
        runner.sendJSONRPCCommandDirect(request) { response in
            DispatchQueue.main.async { completion(response) }
        }
    }
}
