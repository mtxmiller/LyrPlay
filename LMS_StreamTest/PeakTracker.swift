// File: PeakTracker.swift
// Per-band peak-amplitude tracker for the tvOS visualizer's Winamp preset.
// Each band's peak rises instantly to a new max and decays linearly per frame.
// Renderer holds one instance, calls update(bins:) every draw, and uploads
// `peaks` to the bar shader as a small buffer alongside the bins. Bloom + LED +
// iTunes shaders ignore the peaks buffer.
//
// Pure-Foundation, lives in the shared target (iOS + tvOS membership) so it
// can be unit-tested alongside VisualizerEngine. iOS imports but ignores.
//
// Decay rate is per-frame, not per-second — calibrated against a 60fps draw
// loop. Default 0.010 → full decay (1.0 → 0.0) in ~100 frames ≈ 1.6s.
import Foundation

struct PeakTracker {

    /// Per-band peak amplitude. Read by the renderer each frame to upload to the GPU.
    private(set) var peaks: [Float]

    /// How much each peak decays per call to update() when the incoming bin is lower.
    /// Lower = slower fall (peaks linger), higher = faster fall. Default 0.010 →
    /// full decay (1.0 → 0.0) in ~100 frames ≈ 1.6s at 60fps. Tunable via init.
    private let decayPerFrame: Float

    init(bandCount: Int, decayPerFrame: Float = 0.010) {
        self.peaks = Array(repeating: 0, count: Swift.max(0, bandCount))
        self.decayPerFrame = decayPerFrame
    }

    /// Per-frame update. For each band: if the incoming bin exceeds the stored peak,
    /// snap instantly to the new max; otherwise decay by `decayPerFrame`, floored at 0.
    /// Gracefully handles `bins` shorter or longer than the tracker's band count.
    mutating func update(bins: [Float]) {
        let n = Swift.min(peaks.count, bins.count)
        for i in 0..<n {
            let b = bins[i]
            if b > peaks[i] {
                peaks[i] = b
            } else {
                peaks[i] = Swift.max(0, peaks[i] - decayPerFrame)
            }
        }
    }

    /// Reset all peaks to zero. Call on pause/resume and on preset-swap-to-Winamp
    /// so stale pre-pause peaks don't carry over.
    mutating func reset() {
        for i in 0..<peaks.count {
            peaks[i] = 0
        }
    }
}
