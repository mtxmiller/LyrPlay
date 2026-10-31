// File: DownloadPlanPolicy.swift
// Keeping the saved copies in step with the queue while nothing plays
// (bd tcr5, avt6): fill the queue on Wi-Fi before leaving, press Play in the
// car with the songs already on the phone. The download plan used to run only
// at a stream start and a track boundary, so a stopped player never
// downloaded and a queue edit mid-song waited for the next song. Kept pure
// for unit tests.
import Foundation

enum QueueWatchPolicy {
    /// Seconds between queue checks while the 3 s status poll isn't running
    /// (connected, but nothing streamed yet or stopped).
    static let idleInterval: TimeInterval = 10

    /// LMS's `playlist_timestamp` from a status reply (absent = empty queue):
    /// the copies are re-planned on the first reply of a connection and
    /// whenever the queue changes.
    static func replans(seen: Bool, last: Double?, current: Double?) -> Bool {
        !seen || last != current
    }
}

/// What Settings › Offline says about the copies, refreshed once a second
/// while the screen is open.
struct OfflineDownloadStatus: Equatable {
    /// Why nothing downloads right now.
    enum Idle: Equatable {
        case notConnected, syncGroup, waitingForWiFi, streamFirst, storageFull, upToDate
    }

    let savedSeconds: Double
    let plannedSeconds: Double
    let savedCount: Int
    let plannedCount: Int
    /// Downloads still to do, the one in flight included.
    let pendingCount: Int
    /// nil while downloading.
    let idle: Idle?

    /// "18 of 30 min saved · downloading 5 of 9", or the reason it isn't.
    var text: String {
        let minutes = plannedCount == 0 ? "Nothing queued"
            : "\(Self.minutes(savedSeconds)) of \(Self.minutes(plannedSeconds)) min saved"
        let state: String
        switch idle {
        case nil: state = "downloading \(pendingCount) of \(plannedCount)"
        case .notConnected?: state = "not connected"
        case .syncGroup?: state = "off in a sync group"
        case .waitingForWiFi?: state = "waiting for Wi-Fi"
        case .streamFirst?: state = "waiting for the stream to catch up"
        case .storageFull?: state = "storage full"
        case .upToDate?: state = plannedCount == 0 ? "" : "up to date"
        }
        return state.isEmpty ? minutes : "\(minutes) · \(state)"
    }

    private static func minutes(_ seconds: Double) -> Int { Int((seconds / 60).rounded()) }
}
