// File: OfflinePlayerView.swift
// Shown over Material while LMS can't be reached and downloaded copies play
// (ride out network loss). Material is a page served by LMS: offline it
// freezes on its last state, so this is the player until the network is back.
// Buttons go through the coordinator's offline handling, as the lock screen's do.
import SwiftUI
import UIKit

struct OfflinePlayerView: View {
    let state: SlimProtoCoordinator.OfflinePlayerState
    let onCommand: (String) -> Void
    let onPlayTrack: (Int) -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.12, green: 0.12, blue: 0.12).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    header
                    artwork
                    trackInfo
                    progress
                    controls
                    if !state.upNext.isEmpty { upNext }
                    Text("When the network is back, the server picks up where you are.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 2) {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.orange)
                Text(state.minutesLeft < 1 ? "Saved music · under 1 min left"
                                           : "Saved music · \(state.minutesLeft) min left")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .foregroundColor(.white)
        .padding(.top, 8)
    }

    private var artwork: some View {
        Group {
            if let path = state.artworkPath, let image = Self.image(at: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    Color(white: 0.2)
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .frame(maxWidth: 320)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private var trackInfo: some View {
        VStack(spacing: 4) {
            Text(state.current.title)
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
            Text(state.current.artist)
                .foregroundColor(.secondary)
            if !state.album.isEmpty {
                Text(state.album)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(2)
    }

    private var progress: some View {
        let duration = max(state.current.duration, 1)
        let elapsed = min(max(state.elapsed, 0), duration)
        return VStack(spacing: 4) {
            ProgressView(value: elapsed, total: duration)
                .tint(.orange)
            HStack {
                Text(Self.clock(elapsed))
                Spacer()
                Text("-" + Self.clock(duration - elapsed))
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { onCommand("previous") } label: {
                Image(systemName: "backward.end.fill").font(.title)
            }
            .accessibilityLabel("Restart song")
            Button { onCommand(state.isPlaying ? "pause" : "play") } label: {
                Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            Button { onCommand("next") } label: {
                Image(systemName: "forward.end.fill").font(.title)
            }
            .disabled(state.upNext.isEmpty)
            .accessibilityLabel("Next song")
        }
        .foregroundColor(.white)
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved music up next")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.bottom, 6)
            ForEach(state.upNext) { item in
                Button { onPlayTrack(item.index) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).foregroundColor(.white)
                            Text(item.artist).font(.caption).foregroundColor(.secondary)
                        }
                        .lineLimit(1)
                        Spacer()
                        Text(Self.clock(item.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().background(Color(white: 0.3))
            }
        }
    }

    /// The view is rebuilt every second (elapsed time): don't decode the cover each time.
    private static var cachedImage: (path: String, image: UIImage)?
    private static func image(at path: String) -> UIImage? {
        if let cached = cachedImage, cached.path == path { return cached.image }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cachedImage = (path, image)
        return image
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
