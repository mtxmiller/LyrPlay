// VisualizerView.swift
// SwiftUI wrapper around MTKView + VisualizerRenderer for the tvOS visualizer
// overlay. Exposes the visualizer as a SwiftUI view that can be placed inside
// a .fullScreenCover from NowPlayingView.
//
// Pause behavior (D4 from plan-eng-review): when isPlaying becomes false, set
// MTKView.isPaused = true to halt the draw cycle. The last rendered frame stays
// on screen until the user resumes audio. Zero GPU cost while paused.
import SwiftUI
import MetalKit

struct VisualizerView: UIViewRepresentable {

    /// Artwork accent (RGB 0..1). Drives the Metal shader's tint.
    let accentColor: SIMD3<Float>

    /// Pause cue — when false, the renderer halts; last frame stays on screen.
    let isPlaying: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false   // run continuously, not on-demand
        view.isPaused = !isPlaying

        // 1080p drawable per D6 — system upscales to whatever the panel is. Quarter
        // the GPU cost vs native 4K with no perceptible quality loss for abstract
        // music visuals.
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1920, height: 1080)

        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let renderer = VisualizerRenderer.make() {
            renderer.accentColor = accentColor
            renderer.resetEngine()
            view.device = renderer.device
            view.delegate = renderer
            context.coordinator.renderer = renderer
        } else {
            // Metal device or library missing — render a black screen rather than crash.
            view.isPaused = true
        }

        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        if let renderer = context.coordinator.renderer {
            renderer.accentColor = accentColor
        }
        // Pause the draw cycle when audio pauses; the last frame stays on screen.
        view.isPaused = !isPlaying
    }

    final class Coordinator {
        var renderer: VisualizerRenderer?
    }
}
