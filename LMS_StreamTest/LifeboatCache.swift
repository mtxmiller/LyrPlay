// File: LifeboatCache.swift
// Ride out network loss, phase 2: while online, keep downloaded copies of the
// current track and the next ~30 minutes of the queue, so playback can go on
// through a long dead spot. Normal playback still streams; these files are
// only played when the stream dies. Owned by SlimProtoCoordinator (main thread).
import Foundation
import os.log

final class LifeboatCache {
    /// One queue entry LMS gave us (`status - N tags:adlx`).
    struct Track: Equatable {
        let index: Int          // playlist index (play order)
        let id: String          // LMS track id
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let remote: Bool        // radio / streaming service / CUE: can't be downloaded
        var replayGainDB: Double? = nil
    }

    /// Which file to fetch. The copy must decode at the stream's sample rate
    /// so playback can switch to it without a gap: the original for lossless
    /// streams (MobileTranscode re-encodes FLAC at the same rate), Opus (48k)
    /// when the stream is Opus.
    enum Variant: String {
        case original = ""
        case opus = ".ops"
    }

    /// How far ahead to keep copies, in seconds of music from the playhead.
    static let lookahead: TimeInterval = 30 * 60
    static let maxTracks = 20
    static let maxBytes: Int64 = 600 * 1024 * 1024

    private let logger = OSLog(subsystem: "com.lmsstream", category: "Lifeboat")
    private let settings = SettingsManager.shared
    private let directory: URL
    private(set) var plan: [Track] = []
    private var variant: Variant = .original
    private var queue: [Track] = []
    private var active: URLSessionDownloadTask?
    private var activeID: String?
    /// The server answered 400 for the Opus variant (no download rule): use originals.
    private var opusUnavailable = false
    /// Checked before each download (the network may have become metered).
    private var mayDownload: () -> Bool = { true }
    private var allowExpensive = true

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Lifeboat", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Planning

    /// The tracks to keep: from the current one, until `lookahead` seconds
    /// of music are covered (the current track counts from `elapsed`).
    static func select(_ upcoming: [Track], elapsed: Double, lookahead: TimeInterval = lookahead,
                       maxTracks: Int = maxTracks) -> [Track] {
        var covered: Double = 0
        var picked: [Track] = []
        for (i, track) in upcoming.enumerated() where picked.count < maxTracks {
            if covered >= lookahead { break }
            covered += i == 0 ? max(0, track.duration - elapsed) : track.duration
            if !track.remote { picked.append(track) }
        }
        return picked
    }

    /// New queue from LMS. Starts downloading what's missing and deletes
    /// copies that left the window.
    func update(upcoming: [Track], elapsed: Double, streamFormat: String,
                mayDownload: @escaping () -> Bool = { true }, allowExpensive: Bool = true) {
        self.mayDownload = mayDownload
        self.allowExpensive = allowExpensive
        let wanted = Self.select(upcoming, elapsed: elapsed)
        let newVariant: Variant = (streamFormat.lowercased().contains("opus") && !opusUnavailable) ? .opus : .original
        if newVariant != variant {
            variant = newVariant
            removeAll()  // a copy at the wrong rate can't be switched to without a gap
        }
        plan = wanted
        let keep = Set(wanted.map { fileName(for: $0.id) })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where !keep.contains(name) && !name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        queue = wanted.filter { !hasFile($0.id) && $0.id != activeID }  // not again while it downloads
        if let activeID = activeID, !wanted.contains(where: { $0.id == activeID }) {
            active?.cancel()
            active = nil
            self.activeID = nil
        }
        os_log(.info, log: logger, "🛟 Plan: %d tracks (%.0f min), %d to download (%{public}s)",
               wanted.count, wanted.reduce(0) { $0 + $1.duration } / 60, queue.count,
               variant == .opus ? "Opus" : "original")
        downloadNext()
    }

    func track(at index: Int) -> Track? {
        plan.first { $0.index == index }
    }

    /// The downloaded copy of the track at playlist `index`, if complete.
    func fileURL(forIndex index: Int) -> URL? {
        guard let track = track(at: index), hasFile(track.id) else { return nil }
        return directory.appendingPathComponent(fileName(for: track.id))
    }

    func removeAll() {
        active?.cancel()
        active = nil
        activeID = nil
        queue = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Downloads (one at a time)

    private func fileName(for id: String) -> String { "\(id).audio" }

    private func hasFile(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName(for: id)).path)
    }

    private func directorySize() -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(Int64(0)) { sum, name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private func downloadNext() {
        guard active == nil, !queue.isEmpty else { return }
        guard mayDownload() else {
            os_log(.info, log: logger, "🛟 Not downloading now (metered network)")
            return
        }
        guard directorySize() < Self.maxBytes else {
            os_log(.info, log: logger, "🛟 Cache full (%lld MB) - not downloading more", directorySize() / 1_048_576)
            return
        }
        let track = queue.removeFirst()
        let path = "/music/\(track.id)/download\(variant.rawValue)"
        guard let url = URL(string: settings.buildURLString(path: path)) else { return }
        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = allowExpensive
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        if let auth = settings.generateAuthHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let started = Date()
        let usedVariant = variant
        activeID = track.id
        let task = URLSession.lms.downloadTask(with: request) { [weak self] location, response, error in
            // Move the file before returning: the temporary one is deleted afterwards.
            var stored: URL?
            var status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let location = location, error == nil, status == 200 || status == 206, let self = self {
                let dest = self.directory.appendingPathComponent(self.fileName(for: track.id))
                try? FileManager.default.removeItem(at: dest)
                do {
                    try FileManager.default.moveItem(at: location, to: dest)
                    stored = dest
                } catch {
                    status = -1
                }
            }
            DispatchQueue.main.async {
                guard let self = self, self.activeID == track.id else { return }
                self.active = nil
                self.activeID = nil
                if let stored = stored {
                    let size = ((try? FileManager.default.attributesOfItem(atPath: stored.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    os_log(.info, log: self.logger, "🛟 Downloaded track %{public}s (index %d, %.0fs) %.1f MB in %.1fs",
                           track.id, track.index, track.duration, Double(size) / 1_048_576, Date().timeIntervalSince(started))
                } else if usedVariant == .opus && status == 400 {
                    os_log(.info, log: self.logger, "🛟 Server has no Opus download rule - using original files")
                    self.opusUnavailable = true
                    self.variant = .original
                    self.queue.insert(track, at: 0)
                } else {
                    os_log(.error, log: self.logger, "🛟 Download of track %{public}s failed (HTTP %d, %{public}s)",
                           track.id, status, error?.localizedDescription ?? "-")
                }
                self.downloadNext()
            }
        }
        active = task
        task.resume()
    }
}
