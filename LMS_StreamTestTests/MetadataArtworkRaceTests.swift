import XCTest
@testable import LMS_StreamTest

/// Regression tests for the intermittent "synced tvOS player shows stale/wrong
/// cover art or metadata on a track change, then self-heals next track" bug.
///
/// Root cause: out-of-order async responses with no last-write-wins guard, at two
/// async layers (the metadata status fetch, and the artwork download). These tests
/// pin the two guard mechanisms:
///   1. MonotonicGate — drops stale metadata responses, but accepts an earlier
///      good response when the newest fetch fails (so it can't reproduce the bug).
///   2. NowPlayingManager.applyArtwork(_:forGeneration:) — a cover paints only if
///      it belongs to the current track generation, so text and cover never desync.
///
/// All of this logic is synchronous and exercised directly — no network, no async,
/// so the race is deterministic in tests.
final class MetadataArtworkRaceTests: XCTestCase {

    // MARK: - MonotonicGate (metadata last-write-wins)

    func testGateAdmitsIncreasingSeqInOrder() {
        var gate = MonotonicGate()
        XCTAssertTrue(gate.admit(1))
        XCTAssertTrue(gate.admit(2))
        XCTAssertTrue(gate.admit(3))
        XCTAssertEqual(gate.lastAdmitted, 3)
    }

    func testGateDropsStaleResponseThatLandsAfterNewer() {
        // Newer response (seq 5) wins; an older one (seq 4) that lands afterwards
        // must be dropped — this is the core stale-overwrite the bug came from.
        var gate = MonotonicGate()
        XCTAssertTrue(gate.admit(5))
        XCTAssertFalse(gate.admit(4))
        XCTAssertEqual(gate.lastAdmitted, 5)
    }

    func testGateDropsDuplicateSeq() {
        var gate = MonotonicGate()
        XCTAssertTrue(gate.admit(2))
        XCTAssertFalse(gate.admit(2))
    }

    func testGateAcceptsEarlierGoodResponseWhenNewestFetchFails() {
        // THE SELF-HEAL TRAP. fetch seq=6 and seq=7 are issued; seq=7 errors out
        // and never reaches the gate. seq=6's good response arrives. Because the
        // gate tracks last-ADMITTED (5) rather than last-ISSUED (7), seq=6 is
        // still admitted, so the track updates now instead of staying stale until
        // the next boundary. A last-issued gate would WRONGLY drop seq=6 here.
        var gate = MonotonicGate()
        XCTAssertTrue(gate.admit(5))    // some earlier track applied
        // seq 7 issued but failed — never calls admit()
        XCTAssertTrue(gate.admit(6), "earlier good response must still apply when the newest fetch failed")
        XCTAssertEqual(gate.lastAdmitted, 6)
    }

    func testGateInitialStateAdmitsFirstResponse() {
        var gate = MonotonicGate()
        XCTAssertEqual(gate.lastAdmitted, 0)
        XCTAssertTrue(gate.admit(1))
    }

    // MARK: - Artwork generation guard (text/cover never desync)

    private func makeImage(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 4, height: 4)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testApplyArtworkPaintsForCurrentGeneration() {
        let npm = NowPlayingManager()
        npm.updateTrackMetadata(title: "B", artist: "x", album: "y") // no artworkURL -> generation opens, cover cleared
        let gen = npm.currentTrackGenerationForTesting
        let art = makeImage(.red)

        XCTAssertTrue(npm.applyArtwork(art, forGeneration: gen))
        XCTAssertEqual(npm.currentArtwork, art)
    }

    func testApplyArtworkDropsStaleGeneration() {
        let npm = NowPlayingManager()
        // Track B opens (gen N).
        npm.updateTrackMetadata(title: "B", artist: "x", album: "y")
        let genB = npm.currentTrackGenerationForTesting
        // Track C opens (gen N+1) before B's cover download finishes.
        npm.updateTrackMetadata(title: "C", artist: "x", album: "y")
        let artB = makeImage(.blue)

        // B's late cover download must NOT paint over C.
        XCTAssertFalse(npm.applyArtwork(artB, forGeneration: genB))
        XCTAssertNil(npm.currentArtwork, "stale cover for the previous track must not paint")
    }

    func testNewerGenerationCoverPaintsAfterStaleDropped() {
        let npm = NowPlayingManager()
        npm.updateTrackMetadata(title: "B", artist: "x", album: "y")
        let genB = npm.currentTrackGenerationForTesting
        npm.updateTrackMetadata(title: "C", artist: "x", album: "y")
        let genC = npm.currentTrackGenerationForTesting

        XCTAssertFalse(npm.applyArtwork(makeImage(.blue), forGeneration: genB)) // stale B dropped
        XCTAssertTrue(npm.applyArtwork(makeImage(.green), forGeneration: genC))  // current C paints
        XCTAssertNotNil(npm.currentArtwork)
    }

    func testTrackWithNoArtworkClearsPreviousCover() {
        let npm = NowPlayingManager()
        // Track B has a cover.
        npm.updateTrackMetadata(title: "B", artist: "x", album: "y")
        let genB = npm.currentTrackGenerationForTesting
        XCTAssertTrue(npm.applyArtwork(makeImage(.red), forGeneration: genB))
        XCTAssertNotNil(npm.currentArtwork)

        // Track C genuinely has no artwork. updateTrackMetadata with nil URL must
        // clear the cover — the new track must not keep showing B's cover.
        npm.updateTrackMetadata(title: "C", artist: "x", album: "y", artworkURL: nil)
        XCTAssertNil(npm.currentArtwork, "a track with no artwork must clear the previous track's cover")
    }

    func testCurrentTrackArtworkFailureClearsToNoArt() {
        // With the generation guard, only the CURRENT track's load ever paints. A
        // genuine current-track failure applies nil (clear), so the cover never
        // shows the previous track. We simulate the failure branch by applying nil
        // for the current generation (what loadArtwork does on error/invalid data).
        let npm = NowPlayingManager()
        npm.updateTrackMetadata(title: "B", artist: "x", album: "y")
        let genB = npm.currentTrackGenerationForTesting
        XCTAssertTrue(npm.applyArtwork(makeImage(.red), forGeneration: genB))
        XCTAssertNotNil(npm.currentArtwork)

        // Track C opens, its cover load fails -> applyArtwork(nil, genC).
        npm.updateTrackMetadata(title: "C", artist: "x", album: "y")
        let genC = npm.currentTrackGenerationForTesting
        XCTAssertTrue(npm.applyArtwork(nil, forGeneration: genC))
        XCTAssertNil(npm.currentArtwork, "a failed current-track cover must clear, not keep the previous cover")
    }

    // MARK: - Radio-poll artwork dedupe (tvOS "blipping artwork", bd a7r)
    //
    // The 15s radio metadata poll re-sends identical metadata for the playing
    // station. Re-downloading the cover published a fresh UIImage instance every
    // tick, which SwiftUI (reference equality for UIImage) animated as an artwork
    // change — a visible blip on the tvOS Now Playing screen. updateTrackMetadata
    // must leave the painted cover untouched when the incoming URL matches the
    // latched painted URL. applyLoadedArtwork is loadArtwork's synchronous
    // completion step, driven directly here so no real download is needed.

    private let coverURL = "http://server:9000/music/abc/cover.jpg"

    func testRepeatedPollWithSameArtworkURLKeepsCoverInstanceAndGeneration() {
        let npm = NowPlayingManager()
        npm.updateTrackMetadata(title: "Song A", artist: "x", album: "y")
        let gen = npm.currentTrackGenerationForTesting
        let art = makeImage(.red)
        XCTAssertTrue(npm.applyLoadedArtwork(art, from: coverURL, forGeneration: gen))
        XCTAssertEqual(npm.lastLoadedArtworkURLForTesting, coverURL)

        // Radio poll tick: same station, same cover URL (title may even change).
        npm.updateTrackMetadata(title: "Song B", artist: "x", album: "y", artworkURL: coverURL)

        XCTAssertTrue(npm.currentArtwork === art, "unchanged cover URL must keep the SAME UIImage instance (no blip)")
        XCTAssertEqual(npm.currentTrackGenerationForTesting, gen, "dedupe must not open a new generation")
        XCTAssertEqual(npm.currentTrackTitle, "Song B", "text must still repaint on a deduped tick")
    }

    func testFailedLoadDoesNotLatchSoNextPollRetries() {
        let npm = NowPlayingManager()
        npm.updateTrackMetadata(title: "Song A", artist: "x", album: "y")
        let gen = npm.currentTrackGenerationForTesting

        // Cover download fails: clear applies, but the URL must NOT latch.
        XCTAssertTrue(npm.applyLoadedArtwork(nil, from: coverURL, forGeneration: gen))
        XCTAssertNil(npm.currentArtwork)
        XCTAssertNil(npm.lastLoadedArtworkURLForTesting, "failed load must not latch — the next poll must retry")
    }

    func testNewArtworkURLInvalidatesLatchBeforeLoading() {
        // URL-flap safety: once a NEW artwork op starts, the old latch must be
        // gone, so a flap back to the old URL mid-download reloads instead of
        // deduping against a cover that is about to be replaced.
        let npm = NowPlayingManager()
        npm.updateTrackMetadata(title: "Song A", artist: "x", album: "y")
        let gen = npm.currentTrackGenerationForTesting
        XCTAssertTrue(npm.applyLoadedArtwork(makeImage(.red), from: coverURL, forGeneration: gen))
        XCTAssertEqual(npm.lastLoadedArtworkURLForTesting, coverURL)

        // Different cover URL arrives — a real download kicks off (ignored here);
        // synchronously, the latch must already be cleared and a new generation open.
        npm.updateTrackMetadata(title: "Song B", artist: "x", album: "y",
                                artworkURL: "http://server:9000/music/def/cover.jpg")
        XCTAssertNil(npm.lastLoadedArtworkURLForTesting, "starting a new artwork op must invalidate the latch")
        XCTAssertGreaterThan(npm.currentTrackGenerationForTesting, gen)
    }

    func testStaleLoadDoesNotLatch() {
        let npm = NowPlayingManager()
        npm.updateTrackMetadata(title: "Song A", artist: "x", album: "y")
        let genA = npm.currentTrackGenerationForTesting
        // A newer track opens before A's cover lands.
        npm.updateTrackMetadata(title: "Song B", artist: "x", album: "y")

        // A's late cover is dropped by the generation guard and must not latch
        // its URL either — otherwise B's identical-URL poll would dedupe against
        // a cover that never painted.
        XCTAssertFalse(npm.applyLoadedArtwork(makeImage(.red), from: coverURL, forGeneration: genA))
        XCTAssertNil(npm.lastLoadedArtworkURLForTesting)
        XCTAssertNil(npm.currentArtwork)
    }

    func testTrackWithNoArtworkStillClearsAfterLatchedCover() {
        // The nil-URL clear path must be unaffected by the dedupe latch.
        let npm = NowPlayingManager()
        npm.updateTrackMetadata(title: "Song A", artist: "x", album: "y")
        let gen = npm.currentTrackGenerationForTesting
        XCTAssertTrue(npm.applyLoadedArtwork(makeImage(.red), from: coverURL, forGeneration: gen))
        XCTAssertNotNil(npm.currentArtwork)

        npm.updateTrackMetadata(title: "No Art Track", artist: "x", album: "y", artworkURL: nil)
        XCTAssertNil(npm.currentArtwork, "nil-URL track must clear the cover even when a latch is set")
        XCTAssertNil(npm.lastLoadedArtworkURLForTesting)
    }
}
