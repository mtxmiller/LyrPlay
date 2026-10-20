// File: LifeboatCache.swift
// Ride out network loss, phase 2: while online, keep downloaded copies of the
// current track and the next ~30 minutes of the queue, so playback can go on
// through a long dead spot. Normal playback still streams; these files are
// only played when the stream dies. Owned by SlimProtoCoordinator (main thread).
import Foundation
import os.log

final class LifeboatCache {
    /// One queue entry LMS gave us (`status - N tags:adlx`).
    struct Track: Equatable, Codable {
        let index: Int          // playlist index (play order)
        let id: String          // LMS track id
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let remote: Bool        // radio / streaming service / CUE: can't be downloaded
        var replayGainDB: Double? = nil
        var coverID: String? = nil  // LMS artwork id (status tag c), shared by an album's tracks
    }

    /// Which file to fetch. The copy must decode at the stream's sample rate
    /// so playback can switch to it without a gap: the original for lossless
    /// streams (MobileTranscode re-encodes FLAC at the same rate), Opus (48k)
    /// when the stream is Opus.
    enum Variant: String, Codable {
        case original = ""
        case opus = ".lyo"
        case mp3 = ".mp3?bitrate=320"
        case aac = ".aac"
        case ogg = ".lyv"

        /// The copy the server can make in the stream's own format (LMS
        /// transcodes `download.<ext>` when it has a rule): the same kind of
        /// audio as the stream, and a fraction of a lossless original's size.
        /// Downloads carry no player, so only "* *" rules match them. For Opus
        /// and Ogg those come from MobileTranscode 1.4+ as private types (lyo,
        /// lyv): a "* *" ops/ogg rule would also change what squeezelite
        /// players stream. MP3 uses LMS's own rule at the stream's 320k.
        static func forStreamFormat(_ format: String) -> Variant {
            switch format.lowercased() {
            case let f where f.contains("opus"): return .opus
            case "mp3": return .mp3
            case "aac": return .aac
            case "ogg": return .ogg
            default: return .original
            }
        }

        var name: String {
            switch self {
            case .original: return "original"
            case .opus: return "Opus"
            case .mp3: return "MP3"
            case .aac: return "AAC"
            case .ogg: return "Ogg"
            }
        }
    }

    /// How far ahead to keep copies by default, in seconds of music from the
    /// playhead (the setting chooses 15, 30 or 60 minutes).
    static let lookahead: TimeInterval = 30 * 60
    static let maxTracks = 40
    static let maxBytes: Int64 = 600 * 1024 * 1024

    private let logger = OSLog(subsystem: "com.lmsstream", category: "Lifeboat")
    private let settings = SettingsManager.shared
    private let directory: URL
    private(set) var plan: [Track] = []
    private var variant: Variant = .original
    /// The copies are a lossy encode (Opus): a match against the stream can't be exact.
    var copiesAreLossy: Bool { variant != .original }
    private var queue: [Track] = []
    private var active: URLSessionDownloadTask?
    private var activeID: String?
    /// Variants the server answered 400 for (no download rule): use originals.
    private var unavailableVariants: Set<Variant> = []
    /// Checked before each download (the network may have become metered).
    private var mayDownload: () -> Bool = { true }
    private var allowExpensive = true
    /// Format of the stream the copies were made for, and whether LMS applied
    /// ReplayGain to it: what a cold launch without a server needs to play them.
    private(set) var streamFormat = ""
    private(set) var replayGainApplied = false
    /// The server ("host:slimport") the plan's ids and indexes belong to.
    private(set) var server: String?
    private var artworkInFlight: Set<String> = []

    /// The plan, saved next to the files so a relaunch (no server) still knows them.
    private struct SavedPlan: Codable {
        let tracks: [Track]
        let variant: Variant
        let streamFormat: String
        let replayGainApplied: Bool
        var server: String? = nil
        var opusUnavailable: Bool? = nil  // plans saved before unavailableVariants
        var unavailableVariants: [Variant]? = nil
    }
    private static let planFileName = "plan.json"

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Lifeboat", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadPlan()
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
    func update(upcoming: [Track], elapsed: Double, streamFormat: String, replayGainApplied: Bool = false,
                server: String? = nil,
                lookahead: TimeInterval = lookahead,
                mayDownload: @escaping () -> Bool = { true }, allowExpensive: Bool = true) {
        self.mayDownload = mayDownload
        self.allowExpensive = allowExpensive
        let wanted = Self.select(upcoming, elapsed: elapsed, lookahead: lookahead)
        let wantedVariant = Variant.forStreamFormat(streamFormat)
        let newVariant: Variant = unavailableVariants.contains(wantedVariant) ? .original : wantedVariant
        if newVariant != variant {
            variant = newVariant
            removeAll()  // a copy at the wrong rate can't be switched to without a gap
        }
        plan = wanted
        self.streamFormat = streamFormat
        self.replayGainApplied = replayGainApplied
        self.server = server
        savePlan()
        let keep = Set(wanted.map { fileName(for: $0.id) } + wanted.compactMap { $0.coverID.map(artFileName) })
            .union([Self.planFileName])
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where !keep.contains(name) && !name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        queue = wanted.filter { !hasFile($0.id) && $0.id != activeID }  // not again while it downloads
        if mayDownload() {
            // Copies saved before their cover was (or by an older build).
            for track in wanted where hasFile(track.id) { downloadArtwork(for: track) }
        }
        if let activeID = activeID, !wanted.contains(where: { $0.id == activeID }) {
            active?.cancel()
            active = nil
            self.activeID = nil
        }
        os_log(.info, log: logger, "🛟 Plan: %d tracks (%.0f min), %d to download (%{public}s)",
               wanted.count, wanted.reduce(0) { $0 + $1.duration } / 60, queue.count, variant.name)
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

    /// The saved cover of the track at playlist `index`, if downloaded.
    func artworkURL(forIndex index: Int) -> URL? {
        guard let cover = track(at: index)?.coverID else { return nil }
        let url = directory.appendingPathComponent(artFileName(cover))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Space the downloaded copies take, for the settings screen.
    static func storageUsed() -> Int64 {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Lifeboat", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.reduce(Int64(0)) { sum, name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Delete all downloaded copies (the setting was turned off).
    static func clearStorage() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Lifeboat", isDirectory: true)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    func removeAll() {
        plan = []
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
    private func artFileName(_ coverID: String) -> String { "\(coverID).art" }

    /// The cover for the offline player (one per album; small next to the audio).
    private func downloadArtwork(for track: Track) {
        guard let cover = track.coverID, !cover.isEmpty else { return }
        let dest = directory.appendingPathComponent(artFileName(cover))
        guard !FileManager.default.fileExists(atPath: dest.path), !artworkInFlight.contains(cover),
              let url = URL(string: settings.buildURLString(path: "/music/\(cover)/cover_600x600.jpg")) else { return }
        artworkInFlight.insert(cover)
        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = allowExpensive
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        if let auth = settings.generateAuthHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        URLSession.lms.dataTask(with: request) { [weak self] data, response, _ in
            if let data = data, !data.isEmpty, (response as? HTTPURLResponse)?.statusCode == 200 {
                try? data.write(to: dest, options: .atomic)
            }
            DispatchQueue.main.async { self?.artworkInFlight.remove(cover) }
        }.resume()
    }

    private func savePlan() {
        let saved = SavedPlan(tracks: plan, variant: variant, streamFormat: streamFormat,
                              replayGainApplied: replayGainApplied, server: server,
                              unavailableVariants: Array(unavailableVariants))
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.planFileName), options: .atomic)
    }

    private func loadPlan() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.planFileName)),
              let saved = try? JSONDecoder().decode(SavedPlan.self, from: data) else { return }
        plan = saved.tracks
        variant = saved.variant  // else the first update would think the format changed and delete the copies
        streamFormat = saved.streamFormat
        replayGainApplied = saved.replayGainApplied
        server = saved.server
        // Else every launch would retry Opus, see "changed format" and delete the copies (review M7).
        unavailableVariants = Set(saved.unavailableVariants ?? (saved.opusUnavailable == true ? [.opus] : []))
        os_log(.info, log: logger, "🛟 Loaded saved plan: %d tracks (%{public}s)", plan.count, variant.name)
    }

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
                    self.downloadArtwork(for: track)
                } else if usedVariant != .original && status == 400 {
                    os_log(.info, log: self.logger, "🛟 Server has no %{public}s download rule - using original files",
                           usedVariant.name)
                    self.unavailableVariants.insert(usedVariant)
                    self.variant = .original
                    self.savePlan()
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
