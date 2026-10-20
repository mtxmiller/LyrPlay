// File: LifeboatTests.swift
// Ride out network loss, phase 2: finding where a cut stream left off in a
// downloaded copy, the recent-PCM ring, and which tracks to keep.
import Foundation
import Testing
@testable import LMS_StreamTest

private func musicLike(frames: Int, channels: Int, seed: UInt64) -> [Float] {
    // Deterministic noise shaped by a few tones: correlates like real audio.
    var state = seed
    var out = [Float](repeating: 0, count: frames * channels)
    for f in 0..<frames {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int64(bitPattern: state >> 11) % 1000) / 4000
        let t = Float(f) / 44100
        let tone = 0.3 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 331 * t + 1) * sin(2 * .pi * 0.5 * t)
        for c in 0..<channels { out[f * channels + c] = tone + noise * (c == 0 ? 1 : 0.8) }
    }
    return out
}

struct PCMAlignerTests {
    @Test func findsTheExactFrameInIdenticalAudio() throws {
        let window = musicLike(frames: 8 * 44100, channels: 2, seed: 7)
        let start = 3 * 44100 + 1234
        let reference = Array(window[(start * 2)..<((start + 22050) * 2)])
        let match = try #require(PCMAligner.find(reference: reference, in: window, channels: 2))
        #expect(match.frame == start)
        #expect(match.confidence > 0.999)
    }

    @Test func findsItThroughADifferentEncodeAndLevel() throws {
        // Another encode of the same track: small noise, slightly different gain.
        let window = musicLike(frames: 8 * 44100, channels: 2, seed: 11)
        let start = 4 * 44100 - 777
        var state: UInt64 = 99
        let reference: [Float] = window[(start * 2)..<((start + 22050) * 2)].map { x in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return 0.9 * x + Float(Int64(bitPattern: state >> 11) % 100) / 20000
        }
        let match = try #require(PCMAligner.find(reference: reference, in: window, channels: 2))
        #expect(abs(match.frame - start) <= 1)
        #expect(match.confidence > 0.95)
    }

    @Test func noMatchForSilence() {
        let window = [Float](repeating: 0, count: 8 * 44100 * 2)
        let reference = [Float](repeating: 0, count: 22050 * 2)
        #expect(PCMAligner.find(reference: reference, in: window, channels: 2) == nil)
    }

    @Test func lowConfidenceForUnrelatedAudio() throws {
        let window = musicLike(frames: 8 * 44100, channels: 2, seed: 1)
        let other = musicLike(frames: 22050, channels: 2, seed: 2).map { $0 * -1 + 0.01 }
        if let match = PCMAligner.find(reference: other, in: window, channels: 2) {
            #expect(match.confidence < 0.9)
        }
    }
}

struct RecentPCMTests {
    @Test func keepsTheNewestSamplesInOrder() {
        var ring = RecentPCM()
        ring.append([1, 2, 3, 4, 5, 6], count: 6, capacity: 8)
        ring.append([7, 8, 9, 10], count: 4, capacity: 8)
        #expect(ring.last(frames: 4, channels: 2) == [3, 4, 5, 6, 7, 8, 9, 10])
        #expect(ring.last(frames: 1, channels: 2) == [9, 10])
    }

    @Test func aChunkBiggerThanTheRingKeepsItsTail() {
        var ring = RecentPCM()
        ring.append(Array((1...10).map(Float.init)), count: 10, capacity: 4)
        #expect(ring.last(frames: 2, channels: 2) == [7, 8, 9, 10])
    }

    @Test func resetForgetsEverything() {
        var ring = RecentPCM()
        ring.append([1, 2], count: 2, capacity: 4)
        ring.reset()
        #expect(ring.last(frames: 2, channels: 2).isEmpty)
    }
}

struct LifeboatPlanTests {
    private func track(_ i: Int, _ duration: Double, remote: Bool = false) -> LifeboatCache.Track {
        LifeboatCache.Track(index: i, id: "\(i)", title: "", artist: "", album: "", duration: duration, remote: remote)
    }

    @Test func coversTheLookaheadFromThePlayhead() {
        let queue = (0..<10).map { track($0, 300) }   // 5-min tracks
        let picked = LifeboatCache.select(queue, elapsed: 100, lookahead: 30 * 60)
        // 200s left of track 0, then 5 × 300s = 1700s < 1800s, a 7th reaches it.
        #expect(picked.map(\.index) == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test func skipsRemoteTracksButCountsTheirTime() {
        let queue = [track(0, 300), track(1, 600, remote: true), track(2, 300)]
        #expect(LifeboatCache.select(queue, elapsed: 0, lookahead: 30 * 60).map(\.index) == [0, 2])
    }

    @Test func parsesLMSStatus() {
        let status: [String: Any] = ["playlist_loop": [
            ["playlist index": 4, "id": 71531, "title": "A", "artist": "B", "album": "C", "duration": 210.25],
            ["playlist index": "5", "id": "-9", "title": "Radio", "duration": 0, "remote": 1],
        ]]
        let tracks = SlimProtoCoordinator.lifeboatTracks(fromStatus: status)
        #expect(tracks.count == 2)
        #expect(tracks[0] == LifeboatCache.Track(index: 4, id: "71531", title: "A", artist: "B", album: "C",
                                                  duration: 210.25, remote: false))
        #expect(tracks[1].index == 5 && tracks[1].remote)
    }
}

struct DecodeSourceFinishedTests {
    @Test func networkStreamUntilItCloses() {
        #expect(!AudioStreamDecoder.decodeSourceFinished(connected: 1, abandoned: false))
        #expect(AudioStreamDecoder.decodeSourceFinished(connected: 0, abandoned: false))
    }

    @Test func localFilesAndAbandonedStreams() {
        #expect(AudioStreamDecoder.decodeSourceFinished(connected: UInt64.max, abandoned: false))
        #expect(AudioStreamDecoder.decodeSourceFinished(connected: 1, abandoned: true))
    }

    @Test func fileURLs() {
        #expect(AudioStreamDecoder.localFilePath("file:///var/x/Lifeboat/9.audio") == "/var/x/Lifeboat/9.audio")
        #expect(AudioStreamDecoder.localFilePath("http://192.168.1.8:9000/stream.mp3") == nil)
    }
}

struct OfflineMinutesLeftTests {
    private let durations: [Int: Double] = [3: 200, 4: 180, 5: 240, 6: 300]

    @Test func countsTheRestOfThisTrackAndTheCopiesThatFollow() {
        let left = SlimProtoCoordinator.offlineSecondsLeft(
            from: 3, elapsed: 50, duration: { durations[$0] }, hasCopy: { [4, 5].contains($0) })
        #expect(left == 150 + 180 + 240)
    }

    @Test func stopsAtTheFirstMissingCopy() {
        // Track 6 is downloaded but 5 isn't: playback stops after 4.
        let left = SlimProtoCoordinator.offlineSecondsLeft(
            from: 3, elapsed: 0, duration: { durations[$0] }, hasCopy: { [4, 6].contains($0) })
        #expect(left == 200 + 180)
    }

    @Test func neverNegativePastTheEnd() {
        let left = SlimProtoCoordinator.offlineSecondsLeft(
            from: 3, elapsed: 230, duration: { durations[$0] }, hasCopy: { _ in false })
        #expect(left == 0)
    }
}

struct LifeboatVariantTests {
    @Test func copyFollowsTheStreamFormat() {
        #expect(LifeboatCache.Variant.forStreamFormat("Opus") == .opus)
        #expect(LifeboatCache.Variant.forStreamFormat("MP3") == .mp3)
        #expect(LifeboatCache.Variant.forStreamFormat("AAC") == .original)  // no AAC download rule
        #expect(LifeboatCache.Variant.forStreamFormat("OGG") == .ogg)
        #expect(LifeboatCache.Variant.forStreamFormat("FLAC") == .original)
        #expect(LifeboatCache.Variant.forStreamFormat("WAV") == .original)
        #expect(LifeboatCache.Variant.forStreamFormat("") == .original)
    }

    @Test func downloadSuffixes() {
        #expect(LifeboatCache.Variant.original.urlSuffix == "")
        #expect(LifeboatCache.Variant.opus.urlSuffix == ".lyo")
        #expect(LifeboatCache.Variant.ogg.urlSuffix == ".lyv")
        #expect(LifeboatCache.Variant.mp3.urlSuffix == ".mp3?bitrate=320&quality=0")
    }

    @Test func emptyOrCutOffDownloadsAreRejected() {
        #expect(LifeboatCache.isImplausiblySmall(bytes: 0, duration: 200))
        #expect(LifeboatCache.isImplausiblySmall(bytes: 100_000, duration: 200))  // 4 kbit/s
        #expect(!LifeboatCache.isImplausiblySmall(bytes: 3_200_000, duration: 200))  // 128 kbit/s
        #expect(LifeboatCache.isImplausiblySmall(bytes: 10_000, duration: 0))
    }
}
