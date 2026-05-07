import Testing
import Foundation
import AVFoundation
@testable import LMS_StreamTest_tvOS

/// Smoke check, NOT behavioral verification.
///
/// Hardware verification on Apple TV is the only real signal that HW remote
/// events route correctly. This test guards against accidental removal of the
/// `#if os(tvOS)` activation block at the top of `AudioManager.init()` — if
/// someone deletes it, this test fails and surfaces the regression before
/// hardware testing rolls around.
///
/// Why hardware-only is insufficient: the activateAudioSession() init call could
/// be deleted (or its do-catch silenced) between hardware test cycles. This
/// test catches the most common regression shape.
///
/// Why this test is insufficient on its own: simulator AVAudioSession behavior
/// can differ from a real Apple TV. Category state is checked here; actual
/// Now-Playing-app candidacy and HW remote event dispatch are hardware-only.
@Suite struct AudioSessionActivationTests {

    @Test func sessionCategoryIsPlaybackAfterAudioManagerInit() async throws {
        // Touch the singleton to trigger init(). Idempotent — if init ran in
        // a prior test, the session category is still .playback because
        // activateAudioSession() ran in init.
        _ = AudioManager.shared

        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playback)
    }
}
