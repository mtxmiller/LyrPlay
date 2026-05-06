// File: VisualizerEngine.swift
// FFT band mapping + A-weighting + temporal smoothing for the tvOS visualizer.
// Pure logic, target-shared, unit-testable. The BASS_ChannelGetData call lives
// in the renderer (VisualizerRenderer) — this class processes raw FFT magnitude
// bins into perceptual bands the shader can consume.
//
// Data flow:
//   raw FFT bins (1024 from BASS_DATA_FFT2048)
//     → log-frequency map → bandCount perceptual bands
//     → A-weighting at band center (perceptual loudness)
//     → asymmetric smoothing (rise fast, decay slow)
//     → smoothedBins
import Foundation

final class VisualizerEngine {

    /// BASS_DATA_FFT2048 produces a 2048-sample FFT yielding 1024 magnitude bins.
    static let rawBinCount: Int = 1024
    static let fftSize: Int = 2048

    let sampleRate: Float

    /// Asymmetric smoothing. New > prev (rising): mostly target. New <= prev (falling): mostly previous.
    /// Tuned so visual peaks pop and troughs decay smoothly without flicker.
    private let riseFactor: Float = 0.40   // weight of previous when rising — lower = faster rise
    private let fallFactor: Float = 0.85   // weight of previous when falling — higher = slower decay

    private(set) var smoothedBins: [Float] = []

    init(sampleRate: Float = 44100) {
        self.sampleRate = sampleRate
    }

    /// Process raw FFT magnitude bins into `bandCount` perceptual bands.
    /// Call once per render frame. Returns the current smoothed band values.
    @discardableResult
    func process(rawFFT: [Float], bandCount: Int) -> [Float] {
        ensureSmoothedBuffer(count: bandCount)
        guard bandCount > 0 else { return smoothedBins }
        let target = mapToBands(raw: rawFFT, bandCount: bandCount)
        applySmoothing(target: target)
        return smoothedBins
    }

    /// Current smoothed bands without advancing state. Renderer can pull this
    /// after a process() call from the same frame, or to read state for tests.
    func currentBins() -> [Float] {
        return smoothedBins
    }

    /// Reset all smoothing state to zero. Use after a long pause to avoid the
    /// renderer briefly showing stale bands when audio resumes.
    func reset() {
        smoothedBins = Array(repeating: 0, count: smoothedBins.count)
    }

    /// A-weighting curve approximation (IEC 61672-1) normalized so f=1kHz returns 1.0.
    /// Attenuates bass and very high frequencies to match perceived loudness.
    static func aWeighting(frequency f: Float) -> Float {
        let f2 = f * f
        let num = 12200.0 * 12200.0 * f2 * f2
        let den = (f2 + 20.6 * 20.6)
                * Float(sqrt(Double((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9))))
                * (f2 + 12200.0 * 12200.0)
        guard den > 0 else { return 0 }
        let raf = num / den
        // At 1000 Hz, raf ≈ 0.794328 → divide to normalize to 1.0
        return raf / 0.794328
    }

    // MARK: - Internals

    private func ensureSmoothedBuffer(count: Int) {
        if smoothedBins.count != count {
            smoothedBins = Array(repeating: 0, count: count)
        }
    }

    /// Maps `rawBinCount` linear-frequency bins (each ~21.5 Hz wide at 44.1kHz)
    /// to `bandCount` log-spaced perceptual bands across 30 Hz – min(18 kHz, sr/2.2).
    /// Each output band averages the raw bins falling within its frequency range,
    /// then multiplies by A-weighting at the band's center frequency.
    private func mapToBands(raw: [Float], bandCount: Int) -> [Float] {
        var bands = Array<Float>(repeating: 0, count: bandCount)
        guard !raw.isEmpty, bandCount > 0 else { return bands }

        let binWidth = sampleRate / Float(VisualizerEngine.fftSize)
        let minFreq: Float = 30
        let maxFreq: Float = min(18000, sampleRate * 0.45)
        guard maxFreq > minFreq else { return bands }
        let logMin = log(minFreq)
        let logMax = log(maxFreq)

        for b in 0..<bandCount {
            let fLo = exp(logMin + (logMax - logMin) * Float(b) / Float(bandCount))
            let fHi = exp(logMin + (logMax - logMin) * Float(b + 1) / Float(bandCount))
            let iLoRaw = Int((fLo / binWidth).rounded(.down))
            let iHiRaw = Int((fHi / binWidth).rounded(.up))
            let iLo = max(0, min(raw.count - 1, iLoRaw))
            let iHi = max(iLo, min(raw.count - 1, iHiRaw))

            var sum: Float = 0
            for i in iLo...iHi {
                sum += raw[i]
            }
            let avg = sum / Float(iHi - iLo + 1)

            let fCenter = sqrt(fLo * fHi)
            bands[b] = avg * VisualizerEngine.aWeighting(frequency: fCenter)
        }

        return bands
    }

    private func applySmoothing(target: [Float]) {
        for i in 0..<smoothedBins.count {
            let prev = smoothedBins[i]
            let new = i < target.count ? target[i] : 0
            let factor = (new > prev) ? riseFactor : fallFactor
            smoothedBins[i] = prev * factor + new * (1 - factor)
        }
    }
}
