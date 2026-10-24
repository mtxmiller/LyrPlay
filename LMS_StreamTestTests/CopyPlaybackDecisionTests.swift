// File: CopyPlaybackDecisionTests.swift
// Play saved songs from the file when LMS asks for them (bd 5syr): the
// per-strm decision table, STMd timing for copies, STAT elapsed on a handback.
import Foundation
import Testing
@testable import LMS_StreamTest

private typealias Decision = CopyPlaybackDecision

/// Five songs, ids "10"..."14", LMS on `index`; copies of the songs given.
private func server(index: Int = 1, tracks: Int = 5, repeatMode: Int = 0, time: Double? = 0,
                    duration: Double? = 200, remote: Bool = false, ids: [Int: String]? = nil) -> Decision.ServerState {
    let all = Dictionary(uniqueKeysWithValues: (0..<tracks).map { ($0, "\(10 + $0)") })
    let loop = ids ?? all.filter { $0.key == index || $0.key == index + 1 }
    return Decision.ServerState(index: index, tracks: tracks, repeatMode: repeatMode, time: time,
                                duration: duration, remote: remote, ids: loop)
}

private func copies(_ indexes: [Int], formats: Set<String> = ["Opus"]) -> [Int: Decision.SavedCopy] {
    Dictionary(uniqueKeysWithValues: indexes.map { ($0, Decision.SavedCopy(id: "\(10 + $0)", formats: formats)) })
}

private func decide(format: String = "Opus", enabled: Bool = true, sameServer: Bool = true,
                    afterDecodeEnd: Bool = false, afterDecodeError: Bool = false,
                    server: Decision.ServerState = server(), copies: [Int: Decision.SavedCopy] = copies([0, 1, 2, 3, 4]),
                    playing: Decision.PlayingCopy? = nil, handback: Decision.ExpectedHandback? = nil) -> Decision {
    Decision.decide(strmFormat: format, enabled: enabled, sameServer: sameServer,
                    afterDecodeEnd: afterDecodeEnd, afterDecodeError: afterDecodeError,
                    server: server, copies: copies, playing: playing, handback: handback)
}

private func isStream(_ d: Decision) -> Bool {
    if case .stream = d { return true }
    return false
}

struct CopyPlaybackDecisionTableTests {
    // Row: any strm, setting Off / sync group / radio / another server → stream.
    @Test func offOrSyncGroupStreams() {
        #expect(isStream(decide(enabled: false)))
        #expect(isStream(decide(enabled: false, afterDecodeEnd: true)))
    }

    @Test func syncGroupSeenByLMSStreams() {
        var s = server(index: 1, time: 150)
        s.synced = true
        #expect(isStream(decide(afterDecodeEnd: true, server: s)))
        var start = server(index: 3, time: 0)
        start.synced = true
        #expect(isStream(decide(server: start)))
    }

    @Test func anotherServerStreams() {
        #expect(isStream(decide(sameServer: false)))
        #expect(isStream(decide(sameServer: false, afterDecodeEnd: true)))
    }

    @Test func radioOrServiceStreams() {
        #expect(isStream(decide(server: server(remote: true))))
    }

    // Row: after our STMd, copy of the next song complete → file, gaplessly.
    @Test func nextSongAfterDecodeEndPlaysTheFile() {
        #expect(decide(afterDecodeEnd: true, server: server(index: 1, time: 187)) == .file(index: 2))
    }

    @Test func nextSongWithoutACopyStreams() {
        #expect(isStream(decide(afterDecodeEnd: true, copies: copies([0, 1]))))
    }

    // Row: no STMd pending, server time 0, copy complete → file from 0.
    @Test func startFromZeroPlaysTheFile() {
        #expect(decide(server: server(index: 3, time: 0)) == .file(index: 3))
        #expect(decide(server: server(index: 3, time: 1.2)) == .file(index: 3))
    }

    @Test func startFromZeroWithoutACopyStreams() {
        #expect(isStream(decide(server: server(index: 3, time: 0), copies: copies([0, 1, 2]))))
    }

    // Row: no STMd pending, T > 0, not our jump (a seek, a jump elsewhere) → stream.
    @Test func seekStreams() {
        #expect(isStream(decide(server: server(index: 1, time: 95))))
        #expect(isStream(decide(server: server(index: 1, time: 1.6))))
    }

    @Test func noStatusStreams() {
        var s = server()
        s.index = nil
        #expect(isStream(decide(server: s)))
        #expect(isStream(decide(server: server(tracks: 0, ids: [:]))))
    }

    // A start offset clipped to the song's duration proves nothing.
    @Test func timeClippedToTheDurationStreams() {
        #expect(isStream(decide(server: server(index: 1, time: 0.3, duration: 0.5))))
    }

    // Row: no STMd pending, T > 0, a copy of that song already plays at ≈ T → handback.
    @Test func ourJumpHandsBack() {
        let expected = Decision.ExpectedHandback(index: 2, id: "12", offset: 81.4)
        let d = decide(server: server(index: 2, time: 81.4),
                       playing: Decision.PlayingCopy(id: "12", position: 82.1), handback: expected)
        #expect(d == .handback(startOffset: 81.4))
    }

    @Test func handbackToleratesThreeSecondsOfStartOffset() {
        let expected = Decision.ExpectedHandback(index: 2, id: "12", offset: 80)
        let playing = Decision.PlayingCopy(id: "12", position: 84)
        #expect(decide(server: server(index: 2, time: 82.9), playing: playing, handback: expected) == .handback(startOffset: 82.9))
        #expect(isStream(decide(server: server(index: 2, time: 83.1), playing: playing, handback: expected)))
        #expect(isStream(decide(server: server(index: 2, time: 76.9), playing: playing, handback: expected)))
    }

    @Test func handbackNeedsTheCopyPlayingNearTheJump() {
        let expected = Decision.ExpectedHandback(index: 2, id: "12", offset: 80)
        // Behind what LMS will claim, or further ahead of it than a late jump can be: no handback.
        #expect(isStream(decide(server: server(index: 2, time: 80), playing: Decision.PlayingCopy(id: "12", position: 76.5),
                                handback: expected)))
        #expect(isStream(decide(server: server(index: 2, time: 80), playing: Decision.PlayingCopy(id: "12", position: 141),
                                handback: expected)))
        // Seconds ahead (the jump waited for the server): still ours.
        #expect(decide(server: server(index: 2, time: 80), playing: Decision.PlayingCopy(id: "12", position: 91),
                       handback: expected) == .handback(startOffset: 80))
    }

    // Device log 2026-10-21 15:52: a jump that got no reply landed 25 s after
    // it was sent, while the copy had played on from 11.75 to 37 s. Still ours.
    @Test func aLateJumpOfOursHandsBackHoweverFarTheCopyRan() {
        let expected = Decision.ExpectedHandback(index: 2, id: "12", offset: 11.75)
        #expect(decide(server: server(index: 2, time: 11.7), playing: Decision.PlayingCopy(id: "12", position: 37),
                       handback: expected) == .handback(startOffset: 11.7))
    }

    // A retry on top of a jump that got no reply: two of our jumps are out,
    // and LMS's time says which one its strm answers.
    @Test func theStrmAnswersTheJumpNearestLMSsTime() {
        let first = Decision.ExpectedHandback(index: 18, id: "66746", offset: 11.75)
        let retry = Decision.ExpectedHandback(index: 18, id: "66746", offset: 27.3)
        #expect(Decision.expectedJump([first, retry], nearest: 11.7) == first)
        #expect(Decision.expectedJump([first, retry], nearest: 27.4) == retry)
        #expect(Decision.expectedJump([first, retry], nearest: nil) == retry)
        #expect(Decision.expectedJump([], nearest: 11.7) == nil)
    }

    @Test func handbackNeedsACopyOfThatSongPlaying() {
        let expected = Decision.ExpectedHandback(index: 2, id: "12", offset: 80)
        #expect(isStream(decide(server: server(index: 2, time: 80), playing: nil, handback: expected)))
        #expect(isStream(decide(server: server(index: 2, time: 80), playing: Decision.PlayingCopy(id: "13", position: 80),
                                handback: expected)))
    }

    @Test func handbackNeedsLMSOnTheSongWeAskedFor() {
        let expected = Decision.ExpectedHandback(index: 2, id: "12", offset: 80)
        let playing = Decision.PlayingCopy(id: "12", position: 80)
        // Another index (someone jumped elsewhere meanwhile).
        #expect(isStream(decide(server: server(index: 3, time: 80), playing: playing, handback: expected)))
        // Same index, another song (queue edited).
        #expect(isStream(decide(server: server(index: 2, time: 80, ids: [2: "99", 3: "13"]), playing: playing,
                                handback: expected)))
    }

    // Our jump to the start of a song with a copy: not a handback, the file from 0.
    @Test func jumpToTheStartPlaysTheFile() {
        let expected = Decision.ExpectedHandback(index: 2, id: "12", offset: 0.5)
        #expect(decide(server: server(index: 2, time: 0.5), playing: nil, handback: expected) == .file(index: 2))
    }

    // Repeat modes and the wrap.
    @Test func repeatOneReplaysTheSameSong() {
        #expect(decide(afterDecodeEnd: true, server: server(index: 1, repeatMode: 1, time: 190)) == .file(index: 1))
    }

    @Test func repeatAllWrapsToTheFirstSong() {
        let s = server(index: 4, repeatMode: 2, time: 190, ids: [4: "14", 0: "10"])
        #expect(decide(afterDecodeEnd: true, server: s) == .file(index: 0))
        // LMS didn't list song 0: its id can't be checked.
        #expect(isStream(decide(afterDecodeEnd: true, server: server(index: 4, repeatMode: 2, time: 190, ids: [4: "14"]))))
    }

    @Test func endOfThePlaylistStreams() {
        #expect(isStream(decide(afterDecodeEnd: true, server: server(index: 4, repeatMode: 0, time: 190))))
    }

    // Shuffle: indexes are LMS's play order, the next song is index + 1 with its own id.
    @Test func shuffledQueueFollowsThePlayOrder() {
        let s = server(index: 1, time: 150, ids: [1: "40", 2: "27"])
        let saved: [Int: Decision.SavedCopy] = [2: .init(id: "27", formats: ["Opus"])]
        #expect(decide(afterDecodeEnd: true, server: s, copies: saved) == .file(index: 2))
    }

    @Test func queueChangedStreams() {
        // The copy at index 2 is of another song than LMS now has there.
        let s = server(index: 1, time: 150, ids: [1: "11", 2: "77"])
        #expect(isStream(decide(afterDecodeEnd: true, server: s)))
    }

    @Test func formatMismatchStreams() {
        #expect(isStream(decide(format: "MP3", afterDecodeEnd: true)))
        #expect(isStream(decide(format: "FLAC", server: server(index: 3, time: 0))))
        #expect(decide(format: "FLAC", server: server(index: 3, time: 0), copies: copies([3], formats: ["FLAC"])) == .file(index: 3))
    }

    @Test func afterADecodeErrorStreams() {
        #expect(isStream(decide(afterDecodeEnd: true, afterDecodeError: true)))
        #expect(isStream(decide(afterDecodeError: true, server: server(index: 3, time: 0))))
    }

    @Test func nextIndexFollowsRepeat() {
        #expect(Decision.nextIndex(after: 2, tracks: 5, repeatMode: 0) == 3)
        #expect(Decision.nextIndex(after: 4, tracks: 5, repeatMode: 0) == nil)
        #expect(Decision.nextIndex(after: 4, tracks: 5, repeatMode: 2) == 0)
        #expect(Decision.nextIndex(after: 4, tracks: 5, repeatMode: 1) == 4)
        #expect(Decision.nextIndex(after: 0, tracks: 1, repeatMode: 2) == 0)
    }
}

struct SavedCopyFormatTests {
    @Test func transcodesPlayAsTheirCodec() {
        #expect(LifeboatCache.strmFormats(variant: .opus, sourceType: "flc") == ["Opus"])
        #expect(LifeboatCache.strmFormats(variant: .mp3, sourceType: "flc") == ["MP3"])
        #expect(LifeboatCache.strmFormats(variant: .ogg, sourceType: "flc") == ["OGG"])
    }

    @Test func originalsPlayAsTheirFileType() {
        #expect(LifeboatCache.strmFormats(variant: .original, sourceType: "flc") == ["FLAC"])
        #expect(LifeboatCache.strmFormats(variant: .original, sourceType: "mp3") == ["MP3"])
        #expect(LifeboatCache.strmFormats(variant: .original, sourceType: "wav") == ["WAV", "PCM"])
        #expect(LifeboatCache.strmFormats(variant: .original, sourceType: "alc").isEmpty)
        #expect(LifeboatCache.strmFormats(variant: .original, sourceType: nil).isEmpty)
    }
}

struct CopyPlaybackTimingTests {
    // STMd for a copy: never while it is queued behind the playing song (online).
    @Test func queuedCopyHoldsItsDecodeEnd() {
        #expect(SlimProtoCoordinator.holdsCopyDecodeEnd(live: true, decodingCopy: true, decodingAhead: true))
        #expect(!SlimProtoCoordinator.holdsCopyDecodeEnd(live: true, decodingCopy: true, decodingAhead: false))
        #expect(!SlimProtoCoordinator.holdsCopyDecodeEnd(live: true, decodingCopy: false, decodingAhead: true))
        // Offline the outage code decides (next copy or a held STMd).
        #expect(!SlimProtoCoordinator.holdsCopyDecodeEnd(live: false, decodingCopy: true, decodingAhead: true))
    }

    @Test func statElapsedAfterAHandbackIsRelativeToTheStrm() {
        #expect(SlimProtoCoordinator.statElapsed(decoderSeconds: 95.5, startOffset: 81.4, deciding: false) == 95.5 - 81.4)
        #expect(SlimProtoCoordinator.statElapsed(decoderSeconds: 12, startOffset: 0, deciding: false) == 12)
        #expect(SlimProtoCoordinator.statElapsed(decoderSeconds: 80, startOffset: 81.4, deciding: false) == 0)
        #expect(SlimProtoCoordinator.statElapsed(decoderSeconds: 95.5, startOffset: 0, deciding: true) == 0)
    }
}

// LMS's first status answer after a strm can still show the previous song's
// elapsed (it predates our STMc). Device log 2026-10-24: skipping through
// saved songs on cellular streamed every one of them as a "seek".
struct CopyPlaybackAskAgainTests {
    private func delay(attempt: Int = 0, time: Double? = 150, before: Int? = 3, index: Int? = 4,
                       stale: Double? = 236) -> TimeInterval? {
        Decision.askAgainDelay(attempt: attempt, time: time, indexBefore: before, index: index, staleElapsed: stale)
    }

    @Test func aStartFromZeroIsTakenAtOnce() {
        #expect(delay(time: 0) == nil)
        #expect(delay(time: 1.2) == nil)
        #expect(delay(time: nil) == nil)
    }

    @Test func anotherSongWithAStaleTimeIsAskedTwiceMore() {
        // LMS's elapsed for the old song lags ours by 19s: the old 1s match would not have asked again.
        #expect(delay(attempt: 0) == 0.3)
        #expect(delay(attempt: 1) == 0.7)
        #expect(delay(attempt: 2) == nil)
    }

    @Test func theSameSongIsAskedOnceOnlyWhenTheTimeMatchesOurs() {
        // A seek: LMS's time is nowhere near our last elapsed.
        #expect(delay(time: 95, before: 1, index: 1, stale: 30) == nil)
        // The old song's elapsed echoed back: one more ask.
        #expect(delay(time: 30.4, before: 1, index: 1, stale: 30) == 0.3)
        #expect(delay(attempt: 1, time: 30.4, before: 1, index: 1, stale: 30) == nil)
    }

    @Test func withoutOurElapsedOneMoreAskIsAlwaysWorthIt() {
        // Our jumps awaiting their strm: the time tells them apart, so take a fresh one.
        #expect(delay(time: 95, before: 1, index: 1, stale: nil) == 0.3)
    }

    @Test func noIndexBeforeTheStrmFallsBackToTheTimeMatch() {
        // A strm without a stop before it (gapless): nothing to compare the index with.
        #expect(delay(time: 150, before: nil, index: 4, stale: 236) == nil)
        #expect(delay(time: 236.5, before: nil, index: 4, stale: 236) == 0.3)
    }
}
