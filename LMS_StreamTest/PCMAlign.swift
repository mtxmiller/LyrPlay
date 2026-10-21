// File: PCMAlign.swift
// Finding where a stream left off inside a downloaded copy of the same track
// (ride out network loss, phase 2). LMS never tells a player where in the
// track its stream starts, so the switch point is found by matching audio.
import Accelerate
import Foundation

/// The last few seconds of PCM pushed to the push stream (interleaved float),
/// as a ring buffer. Not thread-safe: the decode queue owns it.
struct RecentPCM {
    private var ring: [Float] = []
    private var writeIndex = 0
    private var filled = 0

    mutating func reset() {
        writeIndex = 0
        filled = 0
    }

    /// Append the first `count` samples of `samples`. `capacity` (samples)
    /// sizes the ring; a change (new format) starts it over.
    mutating func append(_ samples: [Float], count: Int, capacity: Int) {
        guard capacity > 0, count > 0 else { return }
        if ring.count != capacity {
            ring = [Float](repeating: 0, count: capacity)
            reset()
        }
        var remaining = min(count, samples.count)
        var source = max(0, min(count, samples.count) - capacity)  // only the newest fit
        remaining -= source
        while remaining > 0 {
            let n = min(remaining, capacity - writeIndex)
            ring.withUnsafeMutableBufferPointer { dst in
                samples.withUnsafeBufferPointer { src in
                    (dst.baseAddress! + writeIndex).update(from: src.baseAddress! + source, count: n)
                }
            }
            writeIndex = (writeIndex + n) % capacity
            source += n
            remaining -= n
            filled = min(capacity, filled + n)
        }
    }

    /// The newest `frames` frames (fewer if not that much was pushed), oldest first.
    func last(frames: Int, channels: Int) -> [Float] {
        let want = min(frames * channels, filled) / max(channels, 1) * max(channels, 1)
        guard want > 0 else { return [] }
        var out = [Float](repeating: 0, count: want)
        let start = (writeIndex - want + ring.count) % ring.count
        let firstPart = min(want, ring.count - start)
        out.withUnsafeMutableBufferPointer { dst in
            ring.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + start, count: firstPart)
                if want > firstPart {
                    (dst.baseAddress! + firstPart).update(from: src.baseAddress!, count: want - firstPart)
                }
            }
        }
        return out
    }
}

enum PCMAligner {
    struct Match: Equatable {
        /// Frame in the window where the reference starts.
        let frame: Int
        /// Normalized correlation, 0...1 (1 = identical waveform).
        let confidence: Float
    }

    /// Find `reference` (interleaved) inside `window` (interleaved, same
    /// rate and channels). Coarse search at 1/4 rate with vDSP, then a
    /// sample-accurate refinement around the best coarse lag. Nil when either
    /// is too short or silent.
    static func find(reference: [Float], in window: [Float], channels: Int, decimation: Int = 4) -> Match? {
        let r = mono(reference, channels: channels)
        let w = mono(window, channels: channels)
        guard r.count >= 256, w.count > r.count else { return nil }

        let rd = decimate(r, by: decimation)
        let wd = decimate(w, by: decimation)
        guard wd.count > rd.count, let coarse = bestLag(reference: rd, window: wd) else { return nil }

        // Refine at full rate around the coarse lag.
        let center = coarse.lag * decimation
        let lo = max(0, center - 2 * decimation)
        let hi = min(w.count - r.count, center + 2 * decimation)
        guard lo <= hi else { return nil }
        let refEnergy = energy(r, 0, r.count)
        guard refEnergy > 1e-9 else { return nil }
        var best = Match(frame: lo, confidence: -1)
        for lag in lo...hi {
            var dot: Float = 0
            r.withUnsafeBufferPointer { rp in
                w.withUnsafeBufferPointer { wp in
                    vDSP_dotpr(rp.baseAddress!, 1, wp.baseAddress! + lag, 1, &dot, vDSP_Length(r.count))
                }
            }
            let e = energy(w, lag, r.count)
            guard e > 1e-9 else { continue }
            let score = dot / sqrt(refEnergy * e)
            if score > best.confidence { best = Match(frame: lag, confidence: score) }
        }
        return best.confidence >= 0 ? Match(frame: best.frame, confidence: min(1, best.confidence)) : nil
    }

    // MARK: helpers

    static func mono(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let frames = interleaved.count / channels
        var out = [Float](repeating: 0, count: frames)
        interleaved.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for c in 0..<channels {
                    vDSP_vadd(dst.baseAddress!, 1, src.baseAddress! + c, vDSP_Stride(channels),
                              dst.baseAddress!, 1, vDSP_Length(frames))
                }
                var scale = 1 / Float(channels)
                vDSP_vsmul(dst.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(frames))
            }
        }
        return out
    }

    static func decimate(_ x: [Float], by factor: Int) -> [Float] {
        guard factor > 1 else { return x }
        let n = x.count / factor
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            for j in 0..<factor { sum += x[i * factor + j] }
            out[i] = sum / Float(factor)
        }
        return out
    }

    private static func energy(_ x: [Float], _ start: Int, _ count: Int) -> Float {
        var e: Float = 0
        x.withUnsafeBufferPointer { p in
            vDSP_svesq(p.baseAddress! + start, 1, &e, vDSP_Length(count))
        }
        return e
    }

    /// Lag of the best normalized correlation of `reference` within `window`.
    private static func bestLag(reference: [Float], window: [Float]) -> (lag: Int, score: Float)? {
        let n = reference.count
        let lags = window.count - n + 1
        guard lags > 0 else { return nil }
        var corr = [Float](repeating: 0, count: lags)
        window.withUnsafeBufferPointer { wp in
            reference.withUnsafeBufferPointer { rp in
                corr.withUnsafeMutableBufferPointer { cp in
                    vDSP_conv(wp.baseAddress!, 1, rp.baseAddress!, 1, cp.baseAddress!, 1,
                              vDSP_Length(lags), vDSP_Length(n))
                }
            }
        }
        // Sliding window energy from a running sum of squares.
        var squares = [Float](repeating: 0, count: window.count)
        vDSP_vsq(window, 1, &squares, 1, vDSP_Length(window.count))
        var running = [Double](repeating: 0, count: window.count + 1)
        for i in 0..<window.count { running[i + 1] = running[i] + Double(squares[i]) }
        let refEnergy = Double(energy(reference, 0, n))
        guard refEnergy > 1e-9 else { return nil }
        var best: (lag: Int, score: Float)?
        for k in 0..<lags {
            let e = running[k + n] - running[k]
            guard e > 1e-9 else { continue }
            let score = Float(Double(corr[k]) / sqrt(refEnergy * e))
            if best == nil || score > best!.score { best = (k, score) }
        }
        return best
    }
}
