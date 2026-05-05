import SwiftUI
import os.log

struct QueueView: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    let coordinator: SlimProtoCoordinator
    @ObservedObject var settings: SettingsManager
    let accentColor: Color

    @State private var tracks: [PlaylistTrack] = []
    @State private var currentIndex: Int = 0
    @State private var isLoading: Bool = false
    @State private var scrollWorkItem: DispatchWorkItem?

    private let logger = OSLog(subsystem: "com.lmsstream", category: "QueueView")

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if tracks.isEmpty && !isLoading {
                    emptyState
                        .listRowBackground(Color.clear)
                } else {
                    // Identity by array offset (not track.id): LMS playlists may contain
                    // the same track at multiple positions, which would collide on .id.
                    // Highlight by playlistIndex (server's absolute position): if parseLoop
                    // skips a malformed entry, array offsets diverge from server indices.
                    ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                        Button {
                            jumpToTrack(track)
                        } label: {
                            QueueRow(
                                track: track,
                                isCurrent: track.playlistIndex == currentIndex,
                                accentColor: accentColor,
                                artworkURL: artworkURL(for: track)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Up Next")
            .background { background.ignoresSafeArea() }
            .onAppear {
                fetchPlaylist {
                    scrollToCurrent(proxy: proxy, animated: false)
                }
            }
            .onChange(of: nowPlaying.currentTrackTitle) { _, _ in
                // Refresh contents + indicator on track change, but don't yank scroll
                // away from a user who is browsing past rows. Indicator moves on its own.
                fetchPlaylist(completion: nil)
            }
        }
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
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Queue is empty")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    // MARK: - Artwork URL

    private func artworkURL(for track: PlaylistTrack) -> URL? {
        // Prefer coverid; fall back to track id (LMS serves /music/<id>/cover.jpg either way).
        let artworkID: String
        if let coverID = track.artworkURL, !coverID.isEmpty {
            artworkID = coverID
        } else if !track.id.isEmpty {
            artworkID = track.id
        } else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = settings.activeServerHost
        components.port = settings.activeServerWebPort
        components.path = "/music/\(artworkID)/cover_200x200_o.jpg"
        let user = settings.activeServerUsername
        if !user.isEmpty {
            components.user = user
            components.password = settings.activeServerPassword
        }
        return components.url
    }

    // MARK: - Auto-scroll

    private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
        // Find the array offset whose track matches the server's current playlist index.
        // Direct use of currentIndex would be wrong if parseLoop skipped any entries.
        guard let target = tracks.firstIndex(where: { $0.playlistIndex == currentIndex }) else { return }
        // Cancel any in-flight scroll so rapid re-appears don't stack scroll closures.
        scrollWorkItem?.cancel()
        let work = DispatchWorkItem {
            if animated {
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            } else {
                proxy.scrollTo(target, anchor: .center)
            }
        }
        scrollWorkItem = work
        // Defer a tick to give List rows time to mount before scrolling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: - Fetch

    private func fetchPlaylist(completion: (() -> Void)? = nil) {
        isLoading = true
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            // start=0 returns the full playlist from index 0 so array index aligns with playlist_cur_index.
            // Using "-" as start returns tracks from the current track forward, which would offset all indices.
            // tags: d=duration, a=artist, l=album, c=coverid (lowercase — uppercase C silently returns nothing).
            "params": [settings.playerMACAddress, ["status", 0, 9999, "tags:dalc"]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { response in
            DispatchQueue.main.async {
                isLoading = false
                guard let result = response["result"] as? [String: Any] else {
                    os_log(.error, log: logger, "❌ Queue fetch: invalid response (keep prior list)")
                    completion?()
                    return
                }

                if let loop = result["playlist_loop"] as? [[String: Any]] {
                    tracks = PlaylistTrack.parseLoop(loop)
                } else {
                    tracks = []
                }

                if let idx = result["playlist_cur_index"] as? Int {
                    currentIndex = idx
                } else if let idxStr = result["playlist_cur_index"] as? String, let parsed = Int(idxStr) {
                    currentIndex = parsed
                } else {
                    currentIndex = 0
                }

                os_log(.info, log: logger, "✅ Queue: %d tracks, current=%d", tracks.count, currentIndex)
                completion?()
            }
        }
    }

    // MARK: - Tap-to-jump

    private func jumpToTrack(_ track: PlaylistTrack) {
        guard let index = track.playlistIndex else {
            os_log(.error, log: logger, "❌ Queue: track has no playlist index, cannot jump")
            return
        }
        guard index != currentIndex else { return }

        os_log(.info, log: logger, "⏭️ Queue: jumping to track %d (%{public}s)", index, track.title)
        let cmd: [String: Any] = [
            "id": 1,
            "method": "slim.request",
            "params": [settings.playerMACAddress, ["playlist", "index", index]]
        ]
        coordinator.sendJSONRPCCommandDirect(cmd) { _ in
            // Server broadcasts track-change; .onChange(currentTrackTitle) refetches and re-scrolls.
        }
    }
}

// MARK: - Row

private struct QueueRow: View {
    let track: PlaylistTrack
    let isCurrent: Bool
    let accentColor: Color
    let artworkURL: URL?

    var body: some View {
        HStack(spacing: 24) {
            artwork
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isCurrent ? accentColor : Color.primary)

                if let artist = track.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 16)

            trailing
                .frame(width: 88, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if isCurrent { parts.append("Now playing") }
        parts.append(track.title)
        if let artist = track.artist { parts.append(artist) }
        if let dur = track.duration, dur > 0 { parts.append(formatTime(dur)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = artworkURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty, .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial)
            Image(systemName: "music.note")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isCurrent {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title3)
                .foregroundStyle(accentColor)
        } else if let dur = track.duration, dur > 0 {
            Text(formatTime(dur))
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            EmptyView()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let mm = total / 60
        let ss = total % 60
        return String(format: "%d:%02d", mm, ss)
    }
}
