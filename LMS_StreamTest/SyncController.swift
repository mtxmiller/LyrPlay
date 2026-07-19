// File: SyncController.swift
// Multi-room sync drift correction via BASS_ATTRIB_FREQ rate matching.
//
// REPLACES (for corrections ≤ 100ms) the buffer-drain-delayed byte-discard skipAhead
// and the hard-cut pause/resume playSilence. For corrections > 100ms, falls through
// to the existing AudioManager.skipAhead / playSilence paths (rare format-mismatch
// transients where rate matching would converge too slowly).
//
// Mechanism: Ian Luck (BASS author) recommended adjusting playback rate slightly
// rather than dropping data. Phase 1 verification (iPhone) confirmed:
//   • BASS_ATTRIB_FREQ works on push streams (readback exact, audible)
//   • BASS_ChannelSlideAttribute produces smooth glissandos
//   • Rate math is linear: +1% offset measured at 99.996% of expected
//   • Audibility threshold: +1.0% audible, +0.5% inaudible
//
// Math: a +0.5% rate offset closes 5ms of drift per second of playback. So a 10ms
// drift residual saturates the cap and closes in ~2s — well within the server's
// correction cycle (1-2s) and the acceptance criterion (<5s convergence).
//
// Threading: D5 of plan-eng-review locked main-thread marshaling at all entry
// points. All public methods MUST be called from main thread (Coordinator marshals
// inputs from SlimProto socket queue via DispatchQueue.main.async).
//
// Reset triggers (D4): caller must invoke reset() at each of:
//   1. Push stream recreate (format mismatch — AudioStreamDecoder:initializePushStream)
//   2. Deferred track start (format mismatch gapless)
//   3. STMs send (track started — SlimProtoCoordinator.sendTrackStarted)
//   4. Reconnect / recovery (SlimProtoCoordinator.slimProtoDidConnect)
//   5. Server pause (didPauseStream)
//   6. Manual stop / disconnect

import Foundation
import os.log

enum SyncControllerConstants {
    /// Maximum inaudible rate offset, fractional (Test 3: +1.0% audible, +0.5% inaudible).
    static let maxOffsetPct: Double = 0.005

    /// Don't bother correcting residuals smaller than this — within server measurement noise.
    static let deadbandMs: Double = 2.0

    /// Proportional gain: maps drift residual to rate offset.
    /// 10ms × 0.0005 = 0.005 = saturates at cap. So 10ms drift drives max catch-up speed.
    static let proportionalGain: Double = 0.0005

    /// SlideAttribute ramp duration. 200ms is below human pitch-shift detection on
    /// a sustained tone (Phase 1 Test 1b heard smooth glissando).
    static let slideDurationMs: Int = 200

    /// Threshold above which corrections fall through to the legacy hard mechanisms
    /// (byte-discard skipAhead, pause/resume playSilence). Rate matching at the
    /// ±0.5% cap would take 20+ seconds to close 100ms — too slow for transients.
    static let hardCorrectionMs: Double = 100.0
}

final class SyncController {

    private let logger = OSLog(subsystem: "com.lmsstream", category: "SyncController")

    /// Signed drift residual in milliseconds.
    /// Positive = we owe time (server sent skipAhead, we are behind).
    /// Negative = we have surplus (server sent playSilence, we are ahead).
    private var driftResidualMs: Double = 0

    /// Currently applied rate offset (fractional). 0 = nominal.
    private var currentTargetOffsetPct: Double = 0

    /// Wall-clock + byte-position baseline for measuring how much catch-up we've
    /// already applied since the last tick. Decays driftResidualMs as the rate
    /// offset works through the playback buffer.
    private var lastTickWall: Date?
    private var lastTickBytes: UInt64?

    /// Decoder reference for applying rate offsets. Weak: AudioManager.shared owns it.
    weak var audioManager: AudioManager?

    /// Closure to read current playback position in bytes (for self-decay measurement).
    /// Provided by Coordinator since SyncController doesn't directly hold pushStream.
    var positionBytesProvider: (() -> UInt64)?

    /// Closure to read the nominal sample rate × channels × bytesPerSample (for ms math).
    /// Provided by Coordinator. Defaults to 44100×2×4 if unset.
    var nominalBytesPerSecondProvider: (() -> Int)?

    init(audioManager: AudioManager) {
        self.audioManager = audioManager
    }

    // MARK: - Inputs (called from Coordinator on main thread)

    /// Server sent skipAhead command. We are behind by `durationMs`.
    /// Returns true if absorbed (rate-match path); false if caller should fall through
    /// to the existing hard byte-discard mechanism (durationMs > kHardCorrectionMs).
    @discardableResult
    func ingestSkipAhead(durationMs: Double) -> Bool {
        if durationMs > SyncControllerConstants.hardCorrectionMs {
            os_log(.info, log: logger, "⏩ skipAhead %.1fms > %.0fms threshold — falling through to hard discard",
                   durationMs, SyncControllerConstants.hardCorrectionMs)
            return false
        }
        driftResidualMs += durationMs
        os_log(.info, log: logger, "⏩ ingestSkipAhead +%.1fms, residual now %.2fms",
               durationMs, driftResidualMs)
        return true
    }

    /// Server sent playSilence command. We are ahead by `durationMs`.
    /// Returns true if absorbed; false if caller should fall through to existing pause/resume.
    @discardableResult
    func ingestPlaySilence(durationMs: Double) -> Bool {
        if durationMs > SyncControllerConstants.hardCorrectionMs {
            os_log(.info, log: logger, "⏸️ playSilence %.1fms > %.0fms threshold — falling through to hard pause",
                   durationMs, SyncControllerConstants.hardCorrectionMs)
            return false
        }
        driftResidualMs -= durationMs
        os_log(.info, log: logger, "⏸️ ingestPlaySilence -%.1fms, residual now %.2fms",
               durationMs, driftResidualMs)
        return true
    }

    /// Clear residual and snap rate to nominal immediately. Call at the 6 reset sites.
    func reset(reason: String) {
        let oldResidual = driftResidualMs
        let oldOffset = currentTargetOffsetPct
        driftResidualMs = 0
        currentTargetOffsetPct = 0
        lastTickWall = nil
        lastTickBytes = nil
        audioManager?.setRateOffsetPctImmediate(0)
        if abs(oldResidual) > 0.01 || abs(oldOffset) > 0.00001 {
            os_log(.info, log: logger, "🔄 reset (%{public}s): residual %.2fms → 0, offset %.5f%% → 0",
                   reason, oldResidual, oldOffset * 100)
        }
    }

    /// Tick — called from playbackHeartbeatTimer (1 Hz) on main thread.
    /// Measures how much we've already corrected, updates target offset, slides FREQ.
    func tick() {
        guard let bytesProvider = positionBytesProvider else { return }
        let bytesNow = bytesProvider()
        let wallNow = Date()
        let bytesPerSec = Double(nominalBytesPerSecondProvider?() ?? 352800)  // 44100*2*4 fallback

        // 1. Self-decay: measure bytes consumed since last tick vs nominal expectation.
        //    Excess bytes = catch-up we've already applied → subtract from residual.
        if let lastBytes = lastTickBytes, let lastWall = lastTickWall {
            let wallElapsed = wallNow.timeIntervalSince(lastWall)

            // Discontinuity guards: heartbeat is 1Hz, so wall delta should be ~1.0s.
            //   • wallElapsed > 1.5s → heartbeat skipped beats (sync-jiffies wait,
            //     scheduling gap, app foregrounding). The byte position didn't advance
            //     during the gap, but attributing the gap as nominal would book it as
            //     phantom positive drift. Refresh baseline and skip.
            //   • bytesNow < lastBytes → position rewound (push stream flush, recreate,
            //     gapless boundary reset). Same problem; refresh and skip.
            if wallElapsed > 1.5 || bytesNow < lastBytes {
                os_log(.debug, log: logger,
                       "📐 tick: discontinuity (wall=%.3fs, bytes %llu → %llu) — refreshing baseline",
                       wallElapsed, lastBytes, bytesNow)
                lastTickBytes = bytesNow
                lastTickWall = wallNow
                return
            }

            if wallElapsed > 0.0001 {
                let bytesAdvanced = Double(bytesNow - lastBytes)
                let nominalBytes = wallElapsed * bytesPerSec
                let extraBytes = bytesAdvanced - nominalBytes
                var extraMs = (extraBytes / bytesPerSec) * 1000.0

                // Safety cap: at the +0.5% cap, the max legit catch-up per second is
                // 5ms. Allow 2× for measurement jitter; anything beyond is a sign of
                // a missed discontinuity (BASS mid-tick pause, clock skew). Discard.
                let maxLegitMs = SyncControllerConstants.maxOffsetPct * 1000.0 * wallElapsed * 2.0
                if abs(extraMs) > maxLegitMs {
                    os_log(.debug, log: logger,
                           "📐 tick: clamping outsized extraMs %.2f → ±%.2f (likely missed discontinuity)",
                           extraMs, maxLegitMs)
                    extraMs = extraMs > 0 ? maxLegitMs : -maxLegitMs
                }

                driftResidualMs -= extraMs
            }
        }
        lastTickBytes = bytesNow
        lastTickWall = wallNow

        // 2. Compute target offset.
        let targetOffsetPct: Double
        if abs(driftResidualMs) < SyncControllerConstants.deadbandMs {
            targetOffsetPct = 0
        } else {
            let raw = driftResidualMs * SyncControllerConstants.proportionalGain
            targetOffsetPct = max(-SyncControllerConstants.maxOffsetPct,
                                  min(SyncControllerConstants.maxOffsetPct, raw))
        }

        // 3. Slide if target changed meaningfully (avoid spamming SetAttribute every tick).
        if abs(targetOffsetPct - currentTargetOffsetPct) > 1e-6 {
            audioManager?.setRateOffsetPct(targetOffsetPct)
            os_log(.debug, log: logger, "📐 tick: residual=%.2fms, offset %.5f%% → %.5f%%",
                   driftResidualMs, currentTargetOffsetPct * 100, targetOffsetPct * 100)
            currentTargetOffsetPct = targetOffsetPct
        }
    }

    // MARK: - Debug snapshot (for harness / logging)

    var debugDriftResidualMs: Double { driftResidualMs }
    var debugCurrentOffsetPct: Double { currentTargetOffsetPct }
}
