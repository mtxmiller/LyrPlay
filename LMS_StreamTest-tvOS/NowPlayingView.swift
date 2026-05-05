import SwiftUI
import Combine
import MediaPlayer
import os.log

struct NowPlayingView: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager

    @State private var accentColor: Color = .accentColor
    @State private var elapsed: Double = 0
    @State private var isPlaying: Bool = false
    @State private var isConnected: Bool = true
    @State private var isScrubbing: Bool = false
    @State private var scrubElapsed: Double = 0
    @State private var scrubCommitWorkItem: DispatchWorkItem?
    @FocusState private var playbackFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let logger = OSLog(subsystem: "com.lmsstream", category: "NowPlayingView")
    private let scrubStepSeconds: Double = 10.0

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            artworkPanel
                .frame(width: 720, height: 720)

            metadataPanel
                .frame(maxWidth: .infinity, minHeight: 720, alignment: .topLeading)
        }
        .padding(.horizontal, 100)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { background.ignoresSafeArea() }
        .overlay(alignment: .topTrailing) {
            if !isConnected {
                reconnectBadge
                    .padding(.top, 32)
                    .padding(.trailing, 32)
            }
        }
        .onAppear {
            tick()
            updateAccent()                                  // initial sample if artwork already loaded
            // Defer focus assignment so SwiftUI focus engine has time to register focusable views
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                playbackFocused = true
            }
        }
        .onChange(of: nowPlaying.currentArtwork) { _, _ in updateAccent() }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            if let art = nowPlaying.currentArtwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black
            }
            Rectangle()
                .fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    // MARK: - Foreground content

    @ViewBuilder
    private var content: some View {
        HStack(alignment: .center, spacing: 64) {
            artworkPanel
                .frame(maxWidth: .infinity)

            metadataPanel
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Artwork (left half)

    private var artworkPanel: some View {
        ZStack {
            if let art = nowPlaying.currentArtwork {
                Image(uiImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                    Image(systemName: "music.note")
                        .font(.system(size: 120))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 12)
        .opacity(isPlaying ? 1.0 : 0.88)
        .animation(reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.85),
                   value: nowPlaying.currentArtwork)
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.3), value: isPlaying)
    }

    // MARK: - Metadata + transport (right half)

    private var metadataPanel: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            if nowPlaying.hasTrackLoaded {
                trackHeader
            } else {
                emptyState
            }

            Spacer(minLength: 24)

            playbackPanel
                .focusable(true)
                .focused($playbackFocused)
                .onMoveCommand { direction in handleMove(direction) }
                .onPlayPauseCommand { sendCommand(isPlaying ? "pause" : "play") }

            transportRow
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trackHeader: some View {
        VStack(spacing: 16) {
            Text(nowPlaying.currentTrackTitle)
                .font(.system(size: 64, weight: .bold))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)

            Text(nowPlaying.currentArtist)
                .font(.title)                 // 28pt per design D2-2
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)

            Text(nowPlaying.currentAlbum)
                .font(.title3)                // 20pt
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connected to \(settings.effectivePlayerName)")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.primary)

            Text("Start a track from LyrPlay on your phone or your Lyrion server's web interface.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Text("\(settings.activeServerHost):\(settings.activeServerWebPort)")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
    }

    // MARK: - Playback panel (progress + scrub)

    @ViewBuilder
    private var playbackPanel: some View {
        if nowPlaying.hasTrackLoaded && nowPlaying.metadataDuration > 0 {
            progressRow
        } else if nowPlaying.hasTrackLoaded {
            liveRow
        } else {
            EmptyView().frame(height: 1)
        }
    }

    private var progressRow: some View {
        let displayElapsed = isScrubbing ? scrubElapsed : elapsed
        let total = max(nowPlaying.metadataDuration, 1)
        return HStack(spacing: 16) {
            Text(formatTime(displayElapsed))
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)

            ProgressView(value: min(max(displayElapsed / total, 0), 1))
                .tint(accentColor)

            Text(formatTime(nowPlaying.metadataDuration))
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback progress")
        .accessibilityValue("\(formatTime(displayElapsed)) of \(formatTime(nowPlaying.metadataDuration))")
        .accessibilityHint("Swipe left or right to scrub")
    }

    private var liveRow: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
                Text("LIVE")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.12))
            )

            Spacer()
        }
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack(spacing: 0) {
            transportButton(
                systemImage: "backward.fill",
                accessibilityLabel: "Previous Track",
                action: { sendCommand("previous") }
            )
            Spacer()
            transportButton(
                systemImage: isPlaying ? "pause.fill" : "play.fill",
                accessibilityLabel: isPlaying ? "Pause" : "Play",
                isPrimary: true,
                action: { sendCommand(isPlaying ? "pause" : "play") }
            )
            Spacer()
            transportButton(
                systemImage: "forward.fill",
                accessibilityLabel: "Next Track",
                action: { sendCommand("next") }
            )
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private func transportButton(
        systemImage: String,
        accessibilityLabel: String,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Image(systemName: systemImage)
                    .font(.system(size: isPrimary ? 32 : 24, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: isPrimary ? 88 : 72, height: isPrimary ? 88 : 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Reconnect badge

    private var reconnectBadge: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Reconnecting…")
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.thinMaterial)
        )
    }

    // MARK: - Tick / state refresh

    private func tick() {
        let (interpolated, playing) = coordinator.getCurrentInterpolatedTime()
        if !isScrubbing { elapsed = interpolated }
        isPlaying = playing
        isConnected = coordinator.isConnected
    }

    // MARK: - Scrub gesture

    private func handleMove(_ direction: MoveCommandDirection) {
        guard nowPlaying.hasTrackLoaded, nowPlaying.metadataDuration > 0 else { return }

        if !isScrubbing {
            isScrubbing = true
            scrubElapsed = elapsed
        }

        switch direction {
        case .left:
            scrubElapsed = max(0, scrubElapsed - scrubStepSeconds)
        case .right:
            scrubElapsed = min(nowPlaying.metadataDuration, scrubElapsed + scrubStepSeconds)
        case .up, .down:
            return  // Ignore vertical
        @unknown default:
            return
        }

        // Commit on a short debounce; if more swipes arrive, the commit re-arms
        scheduleScrubCommit()
    }

    private func scheduleScrubCommit() {
        scrubCommitWorkItem?.cancel()
        let target = scrubElapsed
        let work = DispatchWorkItem { [scrubElapsed = target] in
            coordinator.seek(toSeconds: scrubElapsed)
            // Hold isScrubbing briefly so UI doesn't snap back before STAT confirms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                isScrubbing = false
            }
        }
        scrubCommitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: - Lock-screen-style command dispatch

    private func sendCommand(_ command: String) {
        coordinator.sendLockScreenCommand(command)
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let mm = total / 60
        let ss = total % 60
        return String(format: "%d:%02d", mm, ss)
    }

    private func updateAccent() {
        guard let image = nowPlaying.currentArtwork else {
            withAnimation { accentColor = .accentColor }
            return
        }
        // CIAreaAverage on large artwork (1200-2048px) can hitch the main thread;
        // sample on a background queue and apply on main.
        DispatchQueue.global(qos: .userInitiated).async {
            let extracted = image.averageColor()
            DispatchQueue.main.async {
                withAnimation {
                    accentColor = extracted.map(Color.init) ?? .accentColor
                }
            }
        }
    }
}


// MARK: - UIImage average color (Core Image CIAreaAverage)

private extension UIImage {
    func averageColor() -> UIColor? {
        guard let inputImage = CIImage(image: self) else { return nil }
        let extentVector = CIVector(
            x: inputImage.extent.origin.x,
            y: inputImage.extent.origin.y,
            z: inputImage.extent.size.width,
            w: inputImage.extent.size.height
        )
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: inputImage, kCIInputExtentKey: extentVector]
        ),
              let outputImage = filter.outputImage
        else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(
            outputImage,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        let r = CGFloat(bitmap[0]) / 255.0
        let g = CGFloat(bitmap[1]) / 255.0
        let b = CGFloat(bitmap[2]) / 255.0
        // Reject very low-saturation (grey) results, return system accent fallback
        let max3 = max(r, g, b)
        let min3 = min(r, g, b)
        let saturation = max3 == 0 ? 0 : (max3 - min3) / max3
        if saturation < 0.15 { return nil }
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
