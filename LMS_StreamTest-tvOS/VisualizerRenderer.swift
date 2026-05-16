// VisualizerRenderer.swift
// Owns the Metal pipeline + per-frame draw cycle for the tvOS visualizer.
// Pulls FFT bins from VisualizerEngine on every draw, processes peaks via
// PeakTracker, uploads bins + peaks to the fragment shader as buffers, encodes
// a single full-screen triangle through whichever pipeline currentPreset selects.
//
// Two pipelines (E3 + E7):
//   - bloomPipelineState: fragment shader = visualizer_fragment (radial bloom)
//   - barPipelineState:   fragment shader = bar_fragment (LED/Winamp/iTunes uber)
//   Both share the same vertex function (visualizer_vertex). Pipeline selection
//   happens per-draw based on currentPreset; cost is one MTL state set per frame.
//
// Buffer bindings (always all 3 bound — Metal ignores unused for the active shader):
//   index 0: Uniforms struct (5 fields; bloom shader ignores the `preset` field
//            by virtue of its local struct declaring only the first 4)
//   index 1: bins   (bandCount floats from VisualizerEngine)
//   index 2: peaks  (bandCount floats from PeakTracker; bloom + LED + iTunes
//            shaders ignore — only Winamp reads it)
//
// Lives in the tvOS target. iOS gets nothing — the visualizer is tvOS-only.
import Foundation
import Metal
import MetalKit
import SwiftUI
import os.log

final class VisualizerRenderer: NSObject, MTKViewDelegate {

    /// 64 perceptual bands — enough angular resolution for a 4K display, fits
    /// comfortably in a small shader-side constant buffer.
    static let bandCount: Int = 64

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bloomPipelineState: MTLRenderPipelineState
    private let barPipelineState: MTLRenderPipelineState
    private let engine: VisualizerEngine
    private let logger = OSLog(subsystem: "com.lmsstream", category: "VisualizerRenderer")

    /// Reusable bins buffer — bandCount * sizeof(Float) bytes.
    private let binsBuffer: MTLBuffer
    /// Reusable peaks buffer — bandCount * sizeof(Float) bytes. Only Winamp reads it.
    private let peaksBuffer: MTLBuffer
    /// Peak amplitude tracker for the Winamp falling-peak-cap effect. Updated every
    /// draw regardless of active preset (cost is ~64 ops at 60Hz, negligible); the
    /// reset-on-preset-swap behavior below ensures Winamp always starts from zero.
    private var peakTracker = PeakTracker(bandCount: VisualizerRenderer.bandCount)

    /// Set externally on each renderer update — RGB (0..1) sampled from artwork.
    /// Used by bloom + iTunes shaders; LED + Winamp ignore (canonical palettes).
    var accentColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.6, 1.0)

    /// Currently displayed preset. Selects which pipeline + which uniform `preset`
    /// the next draw will use. Setter resets `peakTracker` on change so that
    /// switching TO Winamp from any other preset starts from zero peaks (peaks
    /// accumulated while a non-Winamp preset was visible are not meaningful).
    ///
    /// Default is .bloom per design Premise 1 (upgraders see the existing radial
    /// bloom on first visualizer entry). VisualizerView writes @AppStorage on
    /// every click-pad LEFT/RIGHT swap and propagates here via updateUIView.
    var currentPreset: VisualizerPreset = .bloom {
        didSet {
            if currentPreset != oldValue {
                peakTracker.reset()
            }
        }
    }

    private var startDate: Date = Date()

    /// Backing store reused per draw to avoid 60Hz allocation churn.
    private var rawFFT: [Float] = Array(repeating: 0, count: VisualizerEngine.rawBinCount)

    /// Mirrors the Uniforms struct in BOTH VisualizerShaders.metal and
    /// VisualizerBarShader.metal. Layout must match exactly: bloom shader's struct
    /// declares the first 4 fields only and reads `MemoryLayout<Uniforms>.stride`
    /// bytes (ignores trailing `preset`); bar shader's struct declares all 5.
    /// Stride is 32 bytes (16 for SIMD3<Float>, 4 each for time/aspect/binCount/preset).
    private struct Uniforms {
        var accentColor: SIMD3<Float>
        var time: Float
        var aspect: Float
        var binCount: Int32
        var preset: Int32           // 0=bloom, 1=ledHiFi, 2=winamp, 3=iTunesClean (matches VisualizerPreset.rawValue)
    }

    private init(device: MTLDevice,
                 commandQueue: MTLCommandQueue,
                 bloomPipelineState: MTLRenderPipelineState,
                 barPipelineState: MTLRenderPipelineState,
                 binsBuffer: MTLBuffer,
                 peaksBuffer: MTLBuffer) {
        self.device = device
        self.commandQueue = commandQueue
        self.bloomPipelineState = bloomPipelineState
        self.barPipelineState = barPipelineState
        self.binsBuffer = binsBuffer
        self.peaksBuffer = peaksBuffer
        self.engine = VisualizerEngine()
        super.init()
    }

    /// Build a renderer if Metal device + library + both pipelines + both buffers
    /// can all be assembled. Returns nil if any step fails so the caller
    /// (VisualizerView) can render a black fallback rather than crash.
    static func make() -> VisualizerRenderer? {
        let log = OSLog(subsystem: "com.lmsstream", category: "VisualizerRenderer")

        guard let device = MTLCreateSystemDefaultDevice() else {
            os_log(.error, log: log, "❌ No Metal device — visualizer cannot run")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            os_log(.error, log: log, "❌ Failed to create Metal command queue")
            return nil
        }
        guard let library = try? device.makeDefaultLibrary(bundle: .main) else {
            os_log(.error, log: log, "❌ Failed to load default Metal library — check shader target membership")
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "visualizer_vertex") else {
            os_log(.error, log: log, "❌ Metal function visualizer_vertex not found")
            return nil
        }
        guard let bloomFragmentFn = library.makeFunction(name: "visualizer_fragment") else {
            os_log(.error, log: log, "❌ Metal function visualizer_fragment not found")
            return nil
        }
        guard let barFragmentFn = library.makeFunction(name: "bar_fragment") else {
            os_log(.error, log: log, "❌ Metal function bar_fragment not found — check VisualizerBarShader.metal target membership")
            return nil
        }

        // Bloom pipeline (radial bloom; preserves pre-fkn visualizer for upgraders).
        let bloomDesc = MTLRenderPipelineDescriptor()
        bloomDesc.vertexFunction = vertexFn
        bloomDesc.fragmentFunction = bloomFragmentFn
        bloomDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let bloomPipeline = try? device.makeRenderPipelineState(descriptor: bloomDesc) else {
            os_log(.error, log: log, "❌ Failed to compile bloom Metal render pipeline state")
            return nil
        }

        // Bar pipeline (uber-shader for LED hi-fi / Winamp / iTunes-clean; shares
        // the same vertex function as bloom per E7).
        let barDesc = MTLRenderPipelineDescriptor()
        barDesc.vertexFunction = vertexFn
        barDesc.fragmentFunction = barFragmentFn
        barDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let barPipeline = try? device.makeRenderPipelineState(descriptor: barDesc) else {
            os_log(.error, log: log, "❌ Failed to compile bar Metal render pipeline state")
            return nil
        }

        guard let binsBuf = device.makeBuffer(length: MemoryLayout<Float>.stride * VisualizerRenderer.bandCount,
                                              options: [.storageModeShared]) else {
            os_log(.error, log: log, "❌ Failed to allocate FFT bins buffer")
            return nil
        }
        guard let peaksBuf = device.makeBuffer(length: MemoryLayout<Float>.stride * VisualizerRenderer.bandCount,
                                               options: [.storageModeShared]) else {
            os_log(.error, log: log, "❌ Failed to allocate FFT peaks buffer")
            return nil
        }

        return VisualizerRenderer(device: device,
                                  commandQueue: queue,
                                  bloomPipelineState: bloomPipeline,
                                  barPipelineState: barPipeline,
                                  binsBuffer: binsBuf,
                                  peaksBuffer: peaksBuf)
    }

    // MARK: - Public API (called from VisualizerView coordinator)

    /// Reset smoothing state AND peak tracker when the user enters the overlay so
    /// we don't briefly paint stale data (bands OR peaks) from a previous session.
    func resetEngine() {
        engine.reset()
        peakTracker.reset()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No-op — we recompute aspect per-frame from drawableSize.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // 1. Pull raw FFT from the active BASS stream and process to bands.
        let stream = AudioManager.shared.currentFFTStream()
        if stream != 0 {
            rawFFT.withUnsafeMutableBufferPointer { ptr in
                let result = BASS_ChannelGetData(stream,
                                                 ptr.baseAddress,
                                                 DWORD(BASS_DATA_FFT2048))
                if result == DWORD.max {
                    // BASS error — zero the buffer so engine smoothing decays naturally.
                    for i in 0..<ptr.count { ptr[i] = 0 }
                }
            }
        } else {
            // No active stream — feed silence; engine smoothing decays to 0,
            // peaks decay to 0.
            for i in 0..<rawFFT.count { rawFFT[i] = 0 }
        }
        let bands = engine.process(rawFFT: rawFFT, bandCount: VisualizerRenderer.bandCount)

        // 2. Update peak tracker (cheap; always runs so peaks are accurate for
        //    any future swap-to-Winamp). Reset-on-preset-swap above keeps peaks
        //    fresh per Winamp entry.
        peakTracker.update(bins: bands)

        // 3. Upload bins to GPU.
        let binsPtr = binsBuffer.contents().bindMemory(to: Float.self,
                                                       capacity: VisualizerRenderer.bandCount)
        for i in 0..<bands.count { binsPtr[i] = bands[i] }

        // 4. Upload peaks to GPU.
        let peaksPtr = peaksBuffer.contents().bindMemory(to: Float.self,
                                                         capacity: VisualizerRenderer.bandCount)
        let peaks = peakTracker.peaks
        for i in 0..<peaks.count { peaksPtr[i] = peaks[i] }

        // 5. Build uniforms.
        let drawSize = view.drawableSize
        let aspect = drawSize.height > 0 ? Float(drawSize.width / drawSize.height) : 1.0
        var uniforms = Uniforms(
            accentColor: accentColor,
            time: Float(Date().timeIntervalSince(startDate)),
            aspect: aspect,
            binCount: Int32(VisualizerRenderer.bandCount),
            preset: Int32(currentPreset.rawValue)
        )

        // 6. Select pipeline based on currentPreset. Bloom keeps its own shader;
        //    the 3 bar presets all share barPipelineState (preset uniform selects
        //    the color treatment inside the shader).
        let pipeline: MTLRenderPipelineState
        switch currentPreset {
        case .bloom:
            pipeline = bloomPipelineState
        case .ledHiFi, .winamp, .iTunesClean:
            pipeline = barPipelineState
        }

        // 7. Encode draw call: single full-screen triangle, 3 vertices, no vertex buffer.
        //    All 3 fragment buffers bound regardless of active shader — Metal ignores
        //    buffers the active fragment function doesn't declare. Simpler than
        //    conditionally binding per pipeline.
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<Uniforms>.stride,
                                 index: 0)
        encoder.setFragmentBuffer(binsBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(peaksBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
