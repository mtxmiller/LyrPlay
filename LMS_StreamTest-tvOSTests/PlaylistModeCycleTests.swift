import Testing
@testable import LMS_StreamTest_tvOS

/// Pins the LMS playlist-mode toggle orderings (w53). `toggleShuffleMode` and
/// `toggleRepeatMode` route through these pure functions, so a regression here
/// would silently change what the tvOS Now Playing buttons (and the CarPlay
/// shuffle button) cycle to.
struct PlaylistModeCycleTests {

    @Test func shuffleCyclesOffSongsAlbumsOff() {
        #expect(PlaylistModeCycle.nextShuffle(0) == 1)  // off → songs
        #expect(PlaylistModeCycle.nextShuffle(1) == 2)  // songs → albums
        #expect(PlaylistModeCycle.nextShuffle(2) == 0)  // albums → off
    }

    @Test func repeatCyclesOffAllOneOff() {
        #expect(PlaylistModeCycle.nextRepeat(0) == 2)  // off → all
        #expect(PlaylistModeCycle.nextRepeat(2) == 1)  // all → one
        #expect(PlaylistModeCycle.nextRepeat(1) == 0)  // one → off
    }

    @Test func unknownModesRecoverIntoTheCycle() {
        // A garbled server value must not strand the button — both cycles
        // treat anything out of range as "off".
        #expect(PlaylistModeCycle.nextShuffle(-1) == 1)
        #expect(PlaylistModeCycle.nextShuffle(7) == 1)
        #expect(PlaylistModeCycle.nextRepeat(-1) == 2)
        #expect(PlaylistModeCycle.nextRepeat(7) == 2)
    }

    @Test func threePressesReturnToOff() {
        var shuffle = 0
        var repeatMode = 0
        for _ in 0..<3 {
            shuffle = PlaylistModeCycle.nextShuffle(shuffle)
            repeatMode = PlaylistModeCycle.nextRepeat(repeatMode)
        }
        #expect(shuffle == 0)
        #expect(repeatMode == 0)
    }
}
