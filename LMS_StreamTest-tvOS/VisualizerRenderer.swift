// VisualizerRenderer.swift
// Owns the Metal pipeline + per-frame draw cycle for the tvOS visualizer.
// Pulls FFT bins from VisualizerEngine on every draw, uploads to the fragment
// shader as a buffer, encodes a single full-screen triangle.
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
    private let pipelineState: MTLRenderPipelineState
    private let engine: VisualizerEngine
    private let logger = OSLog(subsystem: "com.lmsstream", category: "VisualizerRenderer")

    /// Reusable bins buffer — 64 * sizeof(Float) = 256 bytes.
    private let binsBuffer: MTLBuffer

    /// Set externally on each renderer update — RGB (0..1) sampled from artwork.
    var accentColor: SIMD3<Float> = SIMD3<Float>(0.5, 0.6, 1.0)

    private var startDate: Date = Date()

    /// Backing store reused per draw to avoid 60Hz allocation churn.
    private var rawFFT: [Float] = Array(repeating: 0, count: VisualizerEngine.rawBinCount)

    private struct Uniforms {
        var accentColor: SIMD3<Float>
        var time: Float
        var aspect: Float
        var binCount: Int32
    }

    private init(device: MTLDevice,
                 commandQueue: MTLCommandQueue,
                 pipelineState: MTLRenderPipelineState,
                 binsBuffer: MTLBuffer) {
        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.binsBuffer = binsBuffer
        self.engine = VisualizerEngine()
        super.init()
    }

    /// Build a renderer if Metal device + library + pipeline can all be assembled.
    /// Returns nil if any step fails so the caller (VisualizerView) can render a black
    /// fallback rather than crash.
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
            os_log(.error, log: log, "❌ Failed to load default Metal library — check VisualizerShaders.metal target membership")
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "visualizer_vertex"),
              let fragmentFn = library.makeFunction(name: "visualizer_fragment") else {
            os_log(.error, log: log, "❌ Metal functions visualizer_vertex / visualizer_fragment not found")
            return nil
        }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDesc) else {
            os_log(.error, log: log, "❌ Failed to compile Metal render pipeline state")
            return nil
        }

        guard let buf = device.makeBuffer(length: MemoryLayout<Float>.stride * VisualizerRenderer.bandCount,
                                          options: [.storageModeShared]) else {
            os_log(.error, log: log, "❌ Failed to allocate FFT bins buffer")
            return nil
        }

        return VisualizerRenderer(device: device,
                                  commandQueue: queue,
                                  pipelineState: pipeline,
                                  binsBuffer: buf)
    }

    // MARK: - Public API (called from VisualizerView coordinator)

    /// Reset smoothing state when the user enters the overlay so we don't briefly
    /// paint stale bands from a previous session.
    func resetEngine() {
        engine.reset()
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
            // No active stream — feed silence; engine smoothing decays to 0.
            for i in 0..<rawFFT.count { rawFFT[i] = 0 }
        }
        let bands = engine.process(rawFFT: rawFFT, bandCount: VisualizerRenderer.bandCount)

        // 2. Upload bins to GPU.
        let binsPtr = binsBuffer.contents().bindMemory(to: Float.self,
                                                       capacity: VisualizerRenderer.bandCount)
        for i in 0..<bands.count { binsPtr[i] = bands[i] }

        // 3. Build uniforms.
        let drawSize = view.drawableSize
        let aspect = drawSize.height > 0 ? Float(drawSize.width / drawSize.height) : 1.0
        var uniforms = Uniforms(
            accentColor: accentColor,
            time: Float(Date().timeIntervalSince(startDate)),
            aspect: aspect,
            binCount: Int32(VisualizerRenderer.bandCount)
        )

        // 4. Encode draw call: single full-screen triangle, 3 vertices, no vertex buffer.
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms,
                                 length: MemoryLayout<Uniforms>.stride,
                                 index: 0)
        encoder.setFragmentBuffer(binsBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
