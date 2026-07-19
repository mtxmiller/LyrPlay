// VisualizerView.swift
// SwiftUI wrapper around the tvOS visualizer overlay. Owns:
//   - Preset state (@AppStorage), driven by click-pad LEFT/RIGHT gestures
//   - Swap-name overlay (fades in for ~2s on each preset change)
//   - First-launch discovery hint (shows once, ~3s, then never again)
//   - Force-one-redraw on preset-swap-while-paused (ARCH-2 / E2)
//
// Mounts the actual MTKView via the private VisualizerMTKView wrapper. NowPlayingView
// presents this struct as a fullScreenCover; .onExitCommand at the cover level
// handles MENU dismissal (system-level event, doesn't need focus).
//
// Why .focusable(true): Step 0 hardware test verified .onMoveCommand doesn't fire
// on Siri Remote gen 1 click-pad swipes unless the view is in the focus chain.
// Adding .focusable gave ~100% reliability across LEFT/RIGHT (verified at couch
// distance on Apple TV 4K).
import SwiftUI
import MetalKit

struct VisualizerView: View {

    /// Artwork-derived accent color. Used by bloom + iTunes presets; LED + Winamp
    /// ignore (canonical palettes per design Premise 4).
    let accentColor: SIMD3<Float>

    /// Pause cue — when false, the MTKView halts its draw cycle (zero GPU cost).
    let isPlaying: Bool

    /// Source of track metadata for the top-leading track-info overlay. SwiftUI
    /// re-renders on @Published changes (currentTrackTitle / currentArtist), so
    /// the .onChange below auto-fires on track transitions.
    @ObservedObject var nowPlaying: NowPlayingManager

    /// Persisted preset choice. Default = bloom (rawValue 0) so fresh installs +
    /// upgraders see the existing radial bloom on first visualizer entry.
    @AppStorage("lyrplay_visualizer_preset") private var presetRaw: Int = VisualizerPreset.bloom.rawValue

    /// One-shot "swipe to change" hint shown on the user's first-ever visualizer
    /// entry. Dismisses on any swipe OR after ~3s, whichever first. Never shows
    /// again across app launches.
    @AppStorage("lyrplay_visualizer_seen_swap_hint") private var hasSeenSwapHint: Bool = false

    @State private var showSwapOverlay: Bool = false
    @State private var showHintOverlay: Bool = false
    @State private var showTrackOverlay: Bool = false
    @State private var swapFadeTask: Task<Void, Never>?
    @State private var trackFadeTask: Task<Void, Never>?

    private var currentPreset: VisualizerPreset {
        VisualizerPreset(rawValue: presetRaw) ?? .bloom
    }

    /// Composite key used to detect track changes. Title + artist is enough for the
    /// overlay's purpose (radio metadata updates also flow through these fields).
    private var trackKey: String {
        "\(nowPlaying.currentTrackTitle)|\(nowPlaying.currentArtist)"
    }

    var body: some View {
        ZStack {
            VisualizerMTKView(
                accentColor: accentColor,
                isPlaying: isPlaying,
                currentPreset: currentPreset
            )

            // Track-info overlay (top-leading capsule, title + artist). Fades in on
            // viz entry AND on each track change. Auto-dismisses after ~5s. Uses
            // Spacer pattern (same as bottom overlays) so it sits at top-leading
            // without changing the ZStack's default alignment.
            if showTrackOverlay && nowPlaying.hasTrackLoaded {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(nowPlaying.currentTrackTitle)
                                .font(.system(size: 36, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(nowPlaying.currentArtist)
                                .font(.system(size: 24, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        Spacer()                                 // push capsule to leading
                    }
                    .padding(.top, 60)
                    .padding(.leading, 80)
                    Spacer()                                     // push to top
                }
                .transition(.opacity)
            }

            // Swap-name overlay (small capsule at bottom-center, "Bloom" / "LED Hi-Fi" / etc.)
            if showSwapOverlay {
                VStack {
                    Spacer()
                    Text(currentPreset.displayName)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 80)
                        .transition(.opacity)
                }
            }

            // First-launch discovery hint (slightly more prominent than swap overlay)
            if showHintOverlay {
                VStack {
                    Spacer()
                    Text("◀  swipe to change visualizer  ▶")
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 18)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 80)
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSwapOverlay)
        .animation(.easeInOut(duration: 0.3), value: showHintOverlay)
        .animation(.easeInOut(duration: 0.3), value: showTrackOverlay)
        // .focusable(true) is REQUIRED for .onMoveCommand to fire on Siri Remote gen 1
        // click-pad swipes. UIViewRepresentable (MTKView) is not in the focus chain
        // by default. Step 0 hardware test verified zero reliability without this.
        .focusable(true)
        .onMoveCommand(perform: handleMove)
        .onAppear(perform: handleAppear)
        .onChange(of: trackKey) { _, _ in
            triggerTrackOverlay()                                // fires on each track change
        }
    }

    // MARK: - Gesture handling

    private func handleMove(_ direction: MoveCommandDirection) {
        let newPreset: VisualizerPreset
        switch direction {
        case .left:  newPreset = currentPreset.previous()
        case .right: newPreset = currentPreset.next()
        default:     return                            // ignore .up / .down (no semantic mapping)
        }

        presetRaw = newPreset.rawValue                 // @AppStorage write -> VisualizerMTKView.updateUIView fires
        triggerSwapOverlay()

        // Dismiss first-launch hint immediately on first user gesture (per design E9).
        if showHintOverlay {
            showHintOverlay = false
            hasSeenSwapHint = true
        }
    }

    private func handleAppear() {
        // Show track-info overlay on viz entry so the user sees what's currently
        // playing without having to wait for the next track change.
        triggerTrackOverlay()

        guard !hasSeenSwapHint else { return }

        showHintOverlay = true
        // 3-second auto-dismiss timer. If the user swipes before this fires,
        // handleMove already set hasSeenSwapHint=true and dismissed the overlay;
        // the guard inside the closure prevents double-write.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if showHintOverlay {
                showHintOverlay = false
                hasSeenSwapHint = true
            }
        }
    }

    private func triggerSwapOverlay() {
        swapFadeTask?.cancel()
        showSwapOverlay = true
        swapFadeTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                showSwapOverlay = false
            } catch {
                // cancelled by next swipe — leave overlay visible; the new task takes over
            }
        }
    }

    /// Pop the track-info overlay for ~5 seconds. Called on viz entry and on each
    /// track change (.onChange of trackKey). Rapid track changes cancel the prior
    /// timer and restart so the most recent track is always visible for the full
    /// duration. No-op if there's no loaded track (guard inside the conditional
    /// view body also covers this).
    private func triggerTrackOverlay() {
        guard nowPlaying.hasTrackLoaded else { return }
        trackFadeTask?.cancel()
        showTrackOverlay = true
        trackFadeTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                showTrackOverlay = false
            } catch {
                // cancelled by next track change — the new task takes over
            }
        }
    }
}

// MARK: - MTKView wrapper

/// Private UIViewRepresentable that owns the MTKView + VisualizerRenderer. Was
/// the entire file pre-step-5; now a child of the outer SwiftUI VisualizerView.
private struct VisualizerMTKView: UIViewRepresentable {

    let accentColor: SIMD3<Float>
    let isPlaying: Bool
    let currentPreset: VisualizerPreset

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false                   // run continuously, not on-demand
        view.isPaused = !isPlaying

        // 1080p drawable per 98q.7 D6 — system upscales to whatever the panel is.
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1920, height: 1080)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        if let renderer = VisualizerRenderer.make() {
            renderer.accentColor = accentColor
            renderer.currentPreset = currentPreset           // seed with persisted preset
            renderer.resetEngine()                           // zero stale bands + peaks
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

            // Detect preset change BEFORE assigning so we know whether to force a redraw.
            let presetChanged = renderer.currentPreset != currentPreset
            renderer.currentPreset = currentPreset           // didSet may reset peakTracker

            // ARCH-2 / E2: If preset changed while paused, force one synchronous draw
            // so the user sees the swap immediately. Without this, the last frame
            // (old preset) would persist until audio resumes.
            if presetChanged && view.isPaused {
                view.draw()                                  // single synchronous frame
                // view.isPaused stays true after — pause optimization (98q.7 D4) intact
            }
        }

        // Pause cue — when false, MTKView halts the draw cycle. Last frame stays on screen.
        view.isPaused = !isPlaying
    }

    final class Coordinator {
        var renderer: VisualizerRenderer?
    }
}
