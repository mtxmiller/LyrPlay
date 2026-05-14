import SwiftUI

/// Async image view with a process-wide in-memory cache.
///
/// SwiftUI's `AsyncImage` re-fetches and re-decodes every time its view
/// remounts. On tvOS, `List` recycles off-screen rows aggressively, so
/// scrolling a long list and back made already-loaded artwork flash to the
/// placeholder and re-hit the network (mherger beta feedback — cover art
/// disappearing on scroll; `LMS_StreamTest-8uq`).
///
/// `CachedAsyncImage` keeps decoded images in a shared `NSCache` keyed by URL —
/// a row that has loaded its artwork once shows it instantly on every later
/// remount, with no network round-trip and no placeholder frame.
struct CachedAsyncImage<Placeholder: View>: View {
    private let url: URL?
    @ViewBuilder private let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        // Seed from cache so a cache hit renders instantly — no placeholder
        // frame when already-loaded artwork remounts during row recycling.
        _image = State(initialValue: url.flatMap { ImageCache.shared.object(forKey: $0 as NSURL) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        // Re-runs when the row is recycled to a different URL.
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        if let cached = ImageCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }
        // Genuine miss — drop any stale image, fetch, decode, cache.
        image = nil
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, let decoded = UIImage(data: data) else { return }
            ImageCache.shared.setObject(decoded, forKey: url as NSURL)
            image = decoded
        } catch {
            // Transient failure — placeholder stays; recovers on the next
            // remount via `.task(id:)`.
        }
    }
}

/// Process-wide decoded-image cache shared by every `CachedAsyncImage`.
/// `NSCache` evicts under memory pressure on its own.
private enum ImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300  // generous — list artwork thumbnails are small
        return cache
    }()
}
