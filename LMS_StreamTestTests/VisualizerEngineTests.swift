import XCTest
@testable import LMS_StreamTest

final class VisualizerEngineTests: XCTestCase {

    // MARK: - Empty / zero input

    func testEmptyInputYieldsZeroBands() {
        let engine = VisualizerEngine()
        let result = engine.process(rawFFT: [], bandCount: 16)
        XCTAssertEqual(result.count, 16)
        XCTAssertTrue(result.allSatisfy { $0 == 0 })
    }

    func testZeroInputYieldsZeroBands() {
        let engine = VisualizerEngine()
        let zero = Array<Float>(repeating: 0, count: VisualizerEngine.rawBinCount)
        let result = engine.process(rawFFT: zero, bandCount: 16)
        XCTAssertEqual(result.count, 16)
        XCTAssertTrue(result.allSatisfy { $0 == 0 })
    }

    func testZeroBandCountReturnsEmpty() {
        let engine = VisualizerEngine()
        let data = Array<Float>(repeating: 0.5, count: VisualizerEngine.rawBinCount)
        let result = engine.process(rawFFT: data, bandCount: 0)
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - Buffer reinit

    func testBandCountChangeReinitializesBuffer() {
        let engine = VisualizerEngine()
        let data = Array<Float>(repeating: 0.5, count: VisualizerEngine.rawBinCount)
        let r1 = engine.process(rawFFT: data, bandCount: 32)
        XCTAssertEqual(r1.count, 32)
        let r2 = engine.process(rawFFT: data, bandCount: 64)
        XCTAssertEqual(r2.count, 64)
    }

    // MARK: - Frequency mapping

    func testLowFrequencyEnergyMapsToLowBands() {
        // Populate bins 1-5 (≈ 21.5 to 107.5 Hz at 44.1kHz / 2048 FFT)
        var raw = Array<Float>(repeating: 0, count: VisualizerEngine.rawBinCount)
        for i in 1...5 { raw[i] = 1.0 }
        let engine = VisualizerEngine()
        var result = [Float]()
        for _ in 0..<60 {
            result = engine.process(rawFFT: raw, bandCount: 32)
        }
        let lowSum = result.prefix(8).reduce(0, +)
        let highSum = result.suffix(8).reduce(0, +)
        XCTAssertGreaterThan(lowSum, highSum,
                             "low bands should dominate when low-frequency bins are populated")
    }

    func testHighFrequencyEnergyMapsToHighBands() {
        // Populate bins 700-799 (≈ 15-17 kHz)
        var raw = Array<Float>(repeating: 0, count: VisualizerEngine.rawBinCount)
        for i in 700..<800 { raw[i] = 1.0 }
        let engine = VisualizerEngine()
        var result = [Float]()
        for _ in 0..<60 {
            result = engine.process(rawFFT: raw, bandCount: 32)
        }
        let lowSum = result.prefix(8).reduce(0, +)
        let highSum = result.suffix(8).reduce(0, +)
        XCTAssertGreaterThan(highSum, lowSum,
                             "high bands should dominate when high-frequency bins are populated")
    }

    // MARK: - Smoothing

    func testSmoothingDecayWithSilence() {
        let engine = VisualizerEngine()
        // Pump a non-trivial pulse for 10 frames
        let pulse = Array<Float>(repeating: 1.0, count: VisualizerEngine.rawBinCount)
        for _ in 0..<10 { _ = engine.process(rawFFT: pulse, bandCount: 16) }
        let peak = engine.currentBins()
        XCTAssertTrue(peak.contains { $0 > 0.1 },
                      "expected non-trivial energy after pulse")

        // Then 60 frames of silence
        let silence = Array<Float>(repeating: 0, count: VisualizerEngine.rawBinCount)
        for _ in 0..<60 { _ = engine.process(rawFFT: silence, bandCount: 16) }
        let final = engine.currentBins()
        // After 60 frames at fallFactor=0.85, prev decays by 0.85^60 ≈ 6e-5 → essentially zero
        for (i, v) in final.enumerated() {
            XCTAssertLessThan(v, 0.05, "band \(i) did not decay sufficiently: \(v)")
        }
    }

    func testSmoothingRiseWithSustainedInput() {
        let engine = VisualizerEngine()
        let target = Array<Float>(repeating: 1.0, count: VisualizerEngine.rawBinCount)
        for _ in 0..<30 { _ = engine.process(rawFFT: target, bandCount: 16) }
        let result = engine.currentBins()
        // After 30 frames at riseFactor=0.40, smoothing converges close to target.
        // Lowest few bands (~30-100 Hz) are heavily attenuated by A-weighting (≈0.01),
        // so the assertion is most-bands-rose, not all-bands-above-threshold.
        let aboveThreshold = result.filter { $0 > 0.1 }.count
        XCTAssertGreaterThanOrEqual(Double(aboveThreshold) / Double(result.count), 0.75,
                                    "smoothing should have converged toward target on ≥75% of bands; got \(aboveThreshold)/\(result.count)")
    }

    // MARK: - A-weighting

    func testAWeightingAt1kHzIsNearUnity() {
        let w = VisualizerEngine.aWeighting(frequency: 1000)
        XCTAssertEqual(w, 1.0, accuracy: 0.05,
                       "A-weighting normalized to 1.0 at 1 kHz reference")
    }

    func testAWeightingAttenuatesBass() {
        let w50 = VisualizerEngine.aWeighting(frequency: 50)
        XCTAssertLessThan(w50, 0.5,
                          "50 Hz should be attenuated significantly relative to 1 kHz")
    }

    func testAWeightingAttenuatesVeryHighFrequencies() {
        let w16k = VisualizerEngine.aWeighting(frequency: 16000)
        XCTAssertLessThan(w16k, 1.0,
                          "16 kHz should attenuate slightly per A-weighting curve")
    }

    // MARK: - Reset

    func testResetClearsSmoothing() {
        let engine = VisualizerEngine()
        let data = Array<Float>(repeating: 0.8, count: VisualizerEngine.rawBinCount)
        for _ in 0..<10 { _ = engine.process(rawFFT: data, bandCount: 16) }
        XCTAssertTrue(engine.currentBins().contains { $0 > 0 })
        engine.reset()
        XCTAssertTrue(engine.currentBins().allSatisfy { $0 == 0 })
        XCTAssertEqual(engine.currentBins().count, 16, "reset preserves buffer size")
    }
}
