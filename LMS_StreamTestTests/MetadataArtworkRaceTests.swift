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
}
