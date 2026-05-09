// File: Phase0SyncVerification.swift
// Phase 0 verification for the multi-room sync drift fix plan.
//
// Tests two BASS behaviors that the plan depends on but BASS docs don't cover:
//   1. BASS_POS_RELATIVE on a push stream advances the read cursor through
//      queued data AND the speaker audibly skips (not just the position number).
//   2. BASS_ChannelPause + BASS_ChannelStart timing on iOS — characterize how
//      long the iOS HAL output ring takes to drain after pause and refill
//      after resume, so Fix 2's pause+timer-resume mechanism can be calibrated.
//
// Plan: ~/.claude/plans/snug-hopping-mountain.md (Phase 0 section).
// REMOVE THIS FILE before shipping.

import Foundation
import AVFoundation
import os.log

#if DEBUG

/// One-shot guard so the verification fires at most once per process.
enum Phase0Trigger {
    static var hasFired: Bool = false
}

enum Phase0SyncVerification {

    private static let log = OSLog(subsystem: "com.lmsstream", category: "Phase0Sync")

    private static let sampleRate: DWORD = 44100
    private static let channels: DWORD = 2

    // MARK: - Public entry point

    /// Run both tests sequentially. Call when no music is playing.
    /// Outputs to Console with `[Phase0Sync]` lines.
    /// Total runtime ~16s: 6s for Test 1, 8s for Test 2, plus 2s pad between.
    static func runFullTest() {
        os_log(.info, log: log, "════════ PHASE 0 SYNC VERIFICATION START ════════")
        let outputLatency = AVAudioSession.sharedInstance().outputLatency
        os_log(.info, log: log,
               "AVAudioSession.outputLatency = %.4f sec (%.1f ms) — predicted HAL drain",
               outputLatency, outputLatency * 1000)
        os_log(.info, log: log,
               "AVAudioSession.sampleRate = %.0f Hz, ioBufferDuration = %.4f sec",
               AVAudioSession.sharedInstance().sampleRate,
               AVAudioSession.sharedInstance().ioBufferDuration)

        runTest1AudibleSeek {
            // Pad between tests so user can recover
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                runTest2PauseResumeTiming {
                    os_log(.info, log: log, "════════ PHASE 0 SYNC VERIFICATION COMPLETE ════════")
                    os_log(.info, log: log, "Compare logged timestamps against what you HEARD.")
                }
            }
        }
    }

    // MARK: - Test 1: audible relative-seek

    /// Plays a 5-second tone with a different frequency each second:
    ///   0-1s: 440 Hz, 1-2s: 880 Hz, 2-3s: 1320 Hz, 3-4s: 1760 Hz, 4-5s: 2200 Hz.
    /// After 1.0s wall clock, calls BASS_ChannelSetPosition with BASS_POS_RELATIVE +1.0s.
    /// User should HEAR a sudden jump from 440 Hz to 1320 Hz (skipping the 880 Hz second).
    private static func runTest1AudibleSeek(completion: @escaping () -> Void) {
        os_log(.info, log: log, "──── TEST 1: audible relative-seek ────")

        let stream = createTestStream()
        guard stream != 0 else { completion(); return }

        let frequencies: [Double] = [440, 880, 1320, 1760, 2200]
        pushTieredTone(into: stream, frequenciesPerSecond: frequencies)

        guard BASS_ChannelPlay(stream, 0) != 0 else {
            os_log(.error, log: log,
                   "Test 1 BASS_ChannelPlay failed — error %d", BASS_ErrorGetCode())
            BASS_StreamFree(stream)
            completion()
            return
        }
        let t0 = Date()
        os_log(.info, log: log,
               "Test 1 playback started at t=0. Listen: 440 Hz now, jump expected at t=1.0s.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let posBefore = BASS_ChannelGetPosition(stream, DWORD(BASS_POS_BYTE))
            let secondsBefore = BASS_ChannelBytes2Seconds(stream, posBefore)
            let elapsed = Date().timeIntervalSince(t0)

            let bytesToSkip = BASS_ChannelSeconds2Bytes(stream, 1.0)
            let result = BASS_ChannelSetPosition(
                stream,
                bytesToSkip,
                DWORD(BASS_POS_BYTE) | DWORD(BASS_POS_RELATIVE)
            )
            let err = BASS_ErrorGetCode()

            let posAfter = BASS_ChannelGetPosition(stream, DWORD(BASS_POS_BYTE))
            let secondsAfter = BASS_ChannelBytes2Seconds(stream, posAfter)

            os_log(.info, log: log,
                   "Test 1 wall t=%.3fs: SetPosition RELATIVE +1.0s called", elapsed)
            os_log(.info, log: log,
                   "  posBefore = %llu (%.3f sec), posAfter = %llu (%.3f sec)",
                   posBefore, secondsBefore, posAfter, secondsAfter)
            os_log(.info, log: log,
                   "  return = %d, BASS_ErrorGetCode = %d", result, err)
            let expectedJump = bytesToSkip
            let actualJump = posAfter > posBefore ? posAfter - posBefore : 0
            os_log(.info, log: log,
                   "  expected jump = %llu bytes (%.3f sec), actual = %llu bytes (%.3f sec)",
                   expectedJump, BASS_ChannelBytes2Seconds(stream, expectedJump),
                   actualJump, BASS_ChannelBytes2Seconds(stream, actualJump))

            os_log(.info, log: log,
                   "Test 1 DECISION: did you hear the tone jump from 440 Hz to ~1320 Hz?")
            os_log(.info, log: log,
                   "  YES + posAfter - posBefore ≈ 1.0s → green light Fix 1")
            os_log(.info, log: log,
                   "  NO + position number changed but no audible jump → BASS may not flush playback buffer; try BASS_POS_FLUSH")
            os_log(.info, log: log,
                   "  NO + return = 0 → seek rejected, fall back to drain-and-re-prefix path")

            // Let the rest of the audio play out so the user can confirm the jump
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                BASS_ChannelStop(stream)
                BASS_StreamFree(stream)
                os_log(.info, log: log, "──── TEST 1 COMPLETE ────")
                completion()
            }
        }
    }

    // MARK: - Test 2: BASS_ChannelPause vs iOS HAL drain timing

    /// Plays continuous 1 kHz tone for 8 seconds. After 2.0s wall clock pauses BASS;
    /// after another 1.0s wall clock resumes BASS. User listens with a stopwatch
    /// (or just listens carefully): when does the speaker actually go silent?
    /// When does it resume? Compare against the logged AVAudioSession.outputLatency.
    private static func runTest2PauseResumeTiming(completion: @escaping () -> Void) {
        os_log(.info, log: log, "──── TEST 2: BASS_ChannelPause vs iOS HAL drain ────")

        let stream = createTestStream()
        guard stream != 0 else { completion(); return }

        // 8 seconds of continuous 1 kHz tone
        pushTieredTone(into: stream, frequenciesPerSecond: Array(repeating: 1000.0, count: 8))

        guard BASS_ChannelPlay(stream, 0) != 0 else {
            os_log(.error, log: log,
                   "Test 2 BASS_ChannelPlay failed — error %d", BASS_ErrorGetCode())
            BASS_StreamFree(stream)
            completion()
            return
        }
        let t0 = Date()
        os_log(.info, log: log,
               "Test 2 playback started at t=0. 1 kHz tone, will pause at t=2.0s, resume at t=3.0s.")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let preLatency = AVAudioSession.sharedInstance().outputLatency
            let pauseWallTime = Date().timeIntervalSince(t0)
            let pauseResult = BASS_ChannelPause(stream)
            let pauseErr = BASS_ErrorGetCode()
            os_log(.info, log: log,
                   "Test 2 wall t=%.3fs: BASS_ChannelPause called (return=%d, err=%d, outputLatency=%.4fs)",
                   pauseWallTime, pauseResult, pauseErr, preLatency)
            os_log(.info, log: log,
                   "  PREDICTION: speaker should go silent at wall t=%.3fs (pauseTime + outputLatency)",
                   pauseWallTime + preLatency)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let postLatency = AVAudioSession.sharedInstance().outputLatency
                let resumeWallTime = Date().timeIntervalSince(t0)
                let resumeResult = BASS_ChannelStart(stream)
                let resumeErr = BASS_ErrorGetCode()
                os_log(.info, log: log,
                       "Test 2 wall t=%.3fs: BASS_ChannelStart called (return=%d, err=%d, outputLatency=%.4fs)",
                       resumeWallTime, resumeResult, resumeErr, postLatency)
                os_log(.info, log: log,
                       "  PREDICTION: speaker should resume at wall t=%.3fs (resumeTime + outputLatency)",
                       resumeWallTime + postLatency)

                os_log(.info, log: log,
                       "Test 2 EXPECTED audible silence duration = 1.000s (= resume wall - pause wall)")
                os_log(.info, log: log,
                       "  If the silence you hear is ≈1.0s and starts/ends with the predicted offsets → symmetric, green light Fix 2 as designed")
                os_log(.info, log: log,
                       "  If silence < 1.0s or asymmetric edges → adjust Fix 2 timing; report the asymmetry value")

                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    BASS_ChannelStop(stream)
                    BASS_StreamFree(stream)
                    os_log(.info, log: log, "──── TEST 2 COMPLETE ────")
                    completion()
                }
            }
        }
    }

    // MARK: - Helpers

    private static func createTestStream() -> HSTREAM {
        let stream = BASS_StreamCreate(
            sampleRate, channels,
            DWORD(BASS_SAMPLE_FLOAT),
            getLyrPlayStreamProcPush(),
            nil
        )
        if stream == 0 {
            os_log(.error, log: log,
                   "BASS_StreamCreate(PUSH) failed — error %d", BASS_ErrorGetCode())
        }
        return stream
    }

    /// Push N seconds of stereo tone, with the i-th second using `frequenciesPerSecond[i]`.
    /// 32-bit float samples, amplitude 0.25 (-12 dBFS).
    private static func pushTieredTone(into stream: HSTREAM, frequenciesPerSecond: [Double]) {
        let amp: Float = 0.25
        let frameCount = Int(sampleRate)  // one second
        var buffer = [Float](repeating: 0, count: frameCount * Int(channels) * frequenciesPerSecond.count)

        for (secondIndex, hz) in frequenciesPerSecond.enumerated() {
            let twoPiFOverSr = 2.0 * Double.pi * hz / Double(sampleRate)
            let baseSample = secondIndex * frameCount * Int(channels)
            for i in 0..<frameCount {
                let s = Float(sin(Double(i) * twoPiFOverSr)) * amp
                let idx = baseSample + i * Int(channels)
                buffer[idx] = s
                buffer[idx + 1] = s
            }
        }

        let byteCount = buffer.count * MemoryLayout<Float>.size
        let pushed = buffer.withUnsafeBufferPointer { ptr -> DWORD in
            ptr.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: byteCount) { raw in
                BASS_StreamPutData(stream, raw, DWORD(byteCount))
            }
        }
        if pushed == DWORD(bitPattern: -1) {
            os_log(.error, log: log,
                   "BASS_StreamPutData failed — error %d", BASS_ErrorGetCode())
        } else {
            let totalSec = Double(frequenciesPerSecond.count)
            os_log(.info, log: log,
                   "Pushed %u bytes (%.1fs of tone, %d distinct frequencies)",
                   pushed, totalSec, frequenciesPerSecond.count)
        }
    }
}

#endif
