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

/// The gain a copy plays with offline, against what LMS sends online
/// (Slim/Player/ReplayGain.pm; bd i1qs: the raw track tag was applied, 6 dB
/// louder than LMS's peak-limited value for the probe album's +8 dB track).
struct OfflineReplayGainTests {
    typealias RG = LifeboatCache.ReplayGain
    static func track(_ index: Int, gain: Double?, album: Double? = -2, albumID: String? = "20", number: Int? = nil) -> LifeboatCache.Track {
        LifeboatCache.Track(index: index, id: "\(150 + index)", title: "", artist: "", album: "", duration: 60, remote: false,
                            replayGainDB: gain, albumID: albumID, trackNumber: number ?? index + 1, albumReplayGainDB: album)
    }

    @Test func trackModeUsesTheTrackGainCappedAtZeroDB() {
        #expect(RG.linear(mode: 1, track: Self.track(0, gain: -6), before: nil, after: nil) == Float(pow(10, -6.0 / 20)))
        #expect(RG.linear(mode: 1, track: Self.track(1, gain: 3), before: nil, after: nil) == 1)   // peak unknown: never louder
        #expect(RG.linear(mode: 1, track: Self.track(2, gain: 8), before: nil, after: nil) == 1)   // LMS: 1.25 with peak .8
        #expect(RG.linear(mode: 1, track: Self.track(0, gain: nil), before: nil, after: nil) == 0)  // no tag: none, as LMS's strm
    }

    @Test func offAppliesNothing() {
        #expect(RG.linear(mode: 0, track: Self.track(0, gain: -6), before: nil, after: nil) == 0)
    }

    @Test func albumModeUsesTheAlbumGain() {
        #expect(RG.gainDB(mode: 2, track: Self.track(1, gain: 3, album: -2), before: nil, after: nil) == -2)
        #expect(RG.gainDB(mode: 2, track: Self.track(1, gain: 3, album: nil), before: nil, after: nil) == nil)
    }

    @Test func smartModeTakesTheAlbumGainOnlyNextToTheSameAlbumsNeighbouringTrack() {
        let t0 = Self.track(0, gain: -6), t1 = Self.track(1, gain: 3), t2 = Self.track(2, gain: 8)
        #expect(RG.gainDB(mode: 3, track: t1, before: t0, after: t2) == -2)
        #expect(RG.gainDB(mode: 3, track: t0, before: nil, after: t1) == -2)        // first of the album: the next matches
        #expect(RG.gainDB(mode: 3, track: t1, before: nil, after: nil) == 3)         // alone: track gain
        let other = Self.track(2, gain: 8, albumID: "21")
        #expect(RG.gainDB(mode: 3, track: t1, before: Self.track(0, gain: -6, albumID: "21"), after: other) == 3)
        let shuffled = Self.track(2, gain: 8, number: 7)                              // same album, not the next track
        #expect(RG.gainDB(mode: 3, track: t1, before: nil, after: shuffled) == 3)
        #expect(RG.gainDB(mode: 3, track: Self.track(1, gain: 3, album: nil), before: t0, after: t2) == 3)  // no album gain
    }
}

/// What FLAC copies are made as before and after a FLAC has streamed
/// (tester 2026-11-01: a queue added while stopped downloaded originals).
struct CopyFormatSeedTests {
    @Test func theFirstCodeWithAFLACRuleIsTheGuess() {
        #expect(LifeboatCache.Variant.forCapabilities("ops,ogg,flc,mp3,aac") == .opus)
        #expect(LifeboatCache.Variant.forCapabilities("ogg,flc,mp3,aac") == .ogg)
        #expect(LifeboatCache.Variant.forCapabilities("mp3,aac") == .mp3)
        #expect(LifeboatCache.Variant.forCapabilities("aac,mp3") == .mp3)  // no FLAC → AAC rule: LMS streams MP3
        #expect(LifeboatCache.Variant.forCapabilities("flc,ops,ogg,alc,aac,mp3") == .original)
        #expect(LifeboatCache.Variant.forCapabilities("wav,flc,ops,ogg,mp3") == .original)
        // The presets as shipped (bd qtqa, y9kp: only Lossless (FLAC) advertises flc).
        #expect(LifeboatCache.Variant.forCapabilities(SettingsManager.AudioFormat.opus.capabilities) == .opus)
        #expect(LifeboatCache.Variant.forCapabilities(SettingsManager.AudioFormat.oggVorbis.capabilities) == .ogg)
        #expect(LifeboatCache.Variant.forCapabilities(SettingsManager.AudioFormat.wavSeekable.capabilities) == .original)
        #expect(LifeboatCache.Variant.forCapabilities(SettingsManager.AudioFormat.flac.capabilities) == .original)
    }

    @Test func customCodesSkipWhatLMSWouldNotPick() {
        #expect(LifeboatCache.Variant.forCapabilities(" OPS , mp3") == .opus)
        #expect(LifeboatCache.Variant.forCapabilities("wma,ops") == .opus)  // unknown code: the next decides
        #expect(LifeboatCache.Variant.forCapabilities("alc,ops") == .opus)
        #expect(LifeboatCache.Variant.forCapabilities("") == .original)
    }

    @Test func seedFollowsLMSsChoice() {
        // prioritizeNative on (LMS default): a player that advertises FLAC gets FLAC natively.
        #expect(LifeboatCache.seedVariant(capabilities: "ops,ogg,flc,mp3,aac", prioritizeNative: true) == .original)
        #expect(LifeboatCache.seedVariant(capabilities: "ops,ogg,flc,mp3,aac", prioritizeNative: false) == .opus)
        // No FLAC advertised: the first format with a rule, either way.
        #expect(LifeboatCache.seedVariant(capabilities: "mp3,aac", prioritizeNative: true) == .mp3)
        #expect(LifeboatCache.seedVariant(capabilities: "aac,mp3", prioritizeNative: true) == .mp3)
        #expect(LifeboatCache.seedVariant(capabilities: "ogg,flc,mp3,aac", prioritizeNative: false) == .ogg)
        #expect(LifeboatCache.seedVariant(capabilities: "", prioritizeNative: false) == .original)
    }

    @Test func serverPrefValues() {
        #expect(SlimProtoCoordinator.prefIsOn("1"))
        #expect(!SlimProtoCoordinator.prefIsOn("0"))
        #expect(SlimProtoCoordinator.prefIsOn(1))
        #expect(!SlimProtoCoordinator.prefIsOn(0))
        #expect(SlimProtoCoordinator.prefIsOn(nil))  // unset: LMS's default is on
    }
}
