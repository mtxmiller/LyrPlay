// File: DownloadPlanPolicyTests.swift
// The copies follow the queue while nothing plays (bd tcr5, avt6).
import Foundation
import Testing
@testable import LMS_StreamTest

struct QueueWatchPolicyTests {
    @Test func theFirstReplyOfAConnectionPlans() {
        #expect(QueueWatchPolicy.replans(seen: false, last: nil, current: 1_730_000_000))
        #expect(QueueWatchPolicy.replans(seen: false, last: nil, current: nil))  // empty queue: still a plan (deletes stale copies)
    }

    @Test func aChangedTimestampPlansAgain() {
        #expect(QueueWatchPolicy.replans(seen: true, last: 1_730_000_000, current: 1_730_000_042))
        #expect(QueueWatchPolicy.replans(seen: true, last: 1_730_000_000, current: nil))  // queue emptied
        #expect(QueueWatchPolicy.replans(seen: true, last: nil, current: 1_730_000_000))  // queue filled
    }

    @Test func theSameTimestampDoesNothing() {
        #expect(!QueueWatchPolicy.replans(seen: true, last: 1_730_000_000, current: 1_730_000_000))
        #expect(!QueueWatchPolicy.replans(seen: true, last: nil, current: nil))
    }
}

struct OfflineDownloadStatusTests {
    private func status(saved: Double, planned: Double, savedCount: Int = 0, plannedCount: Int = 9,
                        pending: Int = 0, idle: OfflineDownloadStatus.Idle?) -> OfflineDownloadStatus {
        OfflineDownloadStatus(savedSeconds: saved, plannedSeconds: planned, savedCount: savedCount,
                              plannedCount: plannedCount, pendingCount: pending, idle: idle)
    }

    @Test func downloading() {
        #expect(status(saved: 18 * 60, planned: 30 * 60 + 20, pending: 5, idle: nil).text
                == "18 of 30 min saved · downloading 5 of 9")
    }

    @Test func upToDate() {
        #expect(status(saved: 29.6 * 60, planned: 29.6 * 60, idle: .upToDate).text == "30 of 30 min saved · up to date")
    }

    @Test func reasons() {
        #expect(status(saved: 0, planned: 1800, pending: 9, idle: .waitingForWiFi).text == "0 of 30 min saved · waiting for Wi-Fi")
        #expect(status(saved: 600, planned: 1800, pending: 6, idle: .streamFirst).text
                == "10 of 30 min saved · waiting for the stream to catch up")
        #expect(status(saved: 600, planned: 1800, pending: 6, idle: .storageFull).text == "10 of 30 min saved · storage full")
        #expect(status(saved: 600, planned: 1800, pending: 6, idle: .notConnected).text == "10 of 30 min saved · not connected")
        #expect(status(saved: 0, planned: 1800, pending: 9, idle: .syncGroup).text == "0 of 30 min saved · off in a sync group")
    }

    @Test func emptyQueue() {
        #expect(status(saved: 0, planned: 0, plannedCount: 0, idle: .upToDate).text == "Nothing queued")
        #expect(status(saved: 0, planned: 0, plannedCount: 0, idle: .notConnected).text == "Nothing queued · not connected")
    }
}
