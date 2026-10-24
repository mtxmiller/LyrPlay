// File: LifeboatCache.swift
// Ride out network loss, phase 2: while online, keep downloaded copies of the
// current track and the next ~30 minutes of the queue, so playback can go on
// through a long dead spot. A song with a complete copy plays from the file
// when LMS asks for it (CopyPlaybackDecision); the others stream, and a copy
// takes over when the stream dies. Owned by SlimProtoCoordinator (main thread).
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
        var sourceType: String? = nil  // LMS content type of the file (status tag o): flc, mp3, ...
    }

    /// Which file to fetch for a track. The copy must be the audio LMS
    /// streams for that track, at its sample rate, so playback can switch to
    /// it mid-song: LMS (with MobileTranscode's LyrPlay rules) transcodes only
    /// FLAC files to the stream format, and streams other files as they are.
    /// So a FLAC file gets the transcode the stream uses, any other file the
    /// original. Raw values are stable ids (saved in plan.json, file names).
    enum Variant: String {
        case original
        case opus
        case mp3
        case ogg

        /// The transcode a FLAC file is streamed as, from that stream's format
        /// (LMS has no AAC download rule: FLAC streamed as AAC gets originals).
        static func forStreamFormat(_ format: String) -> Variant {
            switch format.lowercased() {
            case let f where f.contains("opus"): return .opus
            case "mp3": return .mp3
            case "ogg": return .ogg
            default: return .original
            }
        }

        /// Appended to `/music/<id>/download`. Downloads carry no player, so
        /// only "* *" rules match them. Opus and Ogg come from MobileTranscode
        /// 1.4+ as private types (lyo, lyv): a "* *" ops/ogg rule would also
        /// change what squeezelite players stream. MP3 uses LMS's own rule, at
        /// the stream rule's 320k and LAME quality 0 (the download default is 9).
        var urlSuffix: String {
            switch self {
            case .original: return ""
            case .opus: return ".lyo"
            case .mp3: return ".mp3?bitrate=320&quality=0"
            case .ogg: return ".lyv"
            }
        }

        var name: String {
            switch self {
            case .original: return "original"
            case .opus: return "Opus"
            case .mp3: return "MP3"
            case .ogg: return "Ogg"
            }
        }
    }

    /// How far ahead to keep copies by default, in seconds of music from the
    /// playhead (the setting chooses 15, 30, 60 or 120 minutes).
    static let lookahead: TimeInterval = 30 * 60
    static let maxTracks = 40
    static let maxBytes: Int64 = 600 * 1024 * 1024

    private let logger = OSLog(subsystem: "com.lmsstream", category: "Lifeboat")
    private let settings = SettingsManager.shared
    private let directory: URL
    private(set) var plan: [Track] = []
    /// What FLAC files are streamed as, learned from the stream of a FLAC
    /// track (the setting and the server's prioritizeNative decide it).
    private var flacVariant: Variant = .original
    private var queue: [Track] = []
    private var active: URLSessionDownloadTask?
    private var activeID: String?
    /// Downloads wait while the stream needs the link (SlimProtoCoordinator
    /// decides once a second, bd xrvg): the task in flight is suspended, not
    /// cancelled, and no new one starts.
    private(set) var downloadsHeld = false
    /// "server|variant" the server answered 400 for (no download rule): those
    /// tracks get originals. Per launch, so installing the rule takes effect.
    private var unavailable: Set<String> = []
    /// "id|variant" downloads that failed or came back too short: not again this launch.
    private var failed: Set<String> = []
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
    /// Older plans (one `variant` for all tracks) still decode: unknown keys are ignored.
    private struct SavedPlan: Codable {
        let tracks: [Track]
        let streamFormat: String
        let replayGainApplied: Bool
        var server: String? = nil
        var flacVariant: String? = nil
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
    /// `streamSourceType`: the file type of the track the current stream
    /// belongs to (the next track's while it decodes ahead).
    func update(upcoming: [Track], elapsed: Double, streamFormat: String, streamSourceType: String? = nil,
                replayGainApplied: Bool = false, server: String? = nil,
                lookahead: TimeInterval = lookahead,
                mayDownload: @escaping () -> Bool = { true }, allowExpensive: Bool = true) {
        self.mayDownload = mayDownload
        self.allowExpensive = allowExpensive
        let wanted = Self.select(upcoming, elapsed: elapsed, lookahead: lookahead)
        if streamSourceType == "flc", !streamFormat.isEmpty {
            // The stream playing now is a FLAC file's: that's what FLAC files become.
            // A change only replaces the FLAC tracks' copies (by file name, below).
            let learned = Variant.forStreamFormat(streamFormat)
            if learned != flacVariant {
                os_log(.info, log: logger, "🛟 FLAC files stream as %{public}s: their copies follow", learned.name)
                flacVariant = learned
            }
        }
        plan = wanted
        self.streamFormat = streamFormat
        self.replayGainApplied = replayGainApplied
        self.server = server
        savePlan()
        let keep = Set(wanted.map { fileName(for: $0) } + wanted.compactMap { $0.coverID.map(artFileName) })
            .union([Self.planFileName])
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where !keep.contains(name) && !name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        queue = wanted.filter { !hasFile($0) && $0.id != activeID  // not again while it downloads
            && !failed.contains("\($0.id)|\(variant(for: $0).rawValue)") }
        if mayDownload() {
            // Copies saved before their cover was (or by an older build).
            for track in wanted where hasFile(track) { downloadArtwork(for: track) }
        }
        if let activeID = activeID, !wanted.contains(where: { $0.id == activeID }) {
            active?.cancel()
            active = nil
            self.activeID = nil
        }
        os_log(.info, log: logger, "🛟 Plan: %d tracks (%.0f min), %d to download (%{public}s)",
               wanted.count, wanted.reduce(0) { $0 + $1.duration } / 60, queue.count, flacVariant.name)
        downloadNext()
    }

    func track(at index: Int) -> Track? {
        plan.first { $0.index == index }
    }

    /// The downloaded copy of the track at playlist `index`, if complete.
    func fileURL(forIndex index: Int) -> URL? {
        guard let track = track(at: index), hasFile(track) else { return nil }
        return directory.appendingPathComponent(fileName(for: track))
    }

    /// Some song of the plan has a complete copy.
    var hasSavedCopies: Bool { plan.contains { hasFile($0) } }

    /// The complete copy of the track at playlist `index`, with the strm
    /// formats it is the same audio as (nil = no complete copy).
    func savedCopy(forIndex index: Int) -> CopyPlaybackDecision.SavedCopy? {
        guard let track = track(at: index), hasFile(track) else { return nil }
        return CopyPlaybackDecision.SavedCopy(id: track.id, formats: Self.strmFormats(
            variant: variant(for: track), sourceType: track.sourceType))
    }

    /// The strm format names (SlimProtoCommandHandler.formatName) a copy plays
    /// as: a transcode as its codec, an original as its file type (LMS
    /// streams non-FLAC files as they are). Unknown types match nothing.
    static func strmFormats(variant: Variant, sourceType: String?) -> Set<String> {
        switch variant {
        case .opus: return ["Opus"]
        case .mp3: return ["MP3"]
        case .ogg: return ["OGG"]
        case .original:
            switch sourceType {
            case "flc": return ["FLAC"]
            case "mp3": return ["MP3"]
            case "ogg": return ["OGG"]
            case "ops": return ["Opus"]
            case "aac", "mp4": return ["AAC"]
            case "wav": return ["WAV", "PCM"]
            default: return []
            }
        }
    }

    /// The copy of the track at `index` is a lossy transcode: a match against
    /// the stream can't be exact.
    func copyIsTranscode(forIndex index: Int) -> Bool {
        track(at: index).map { variant(for: $0) != .original } ?? false
    }

    /// The file to fetch for `track`: see `Variant`.
    private func variant(for track: Track) -> Variant {
        guard track.sourceType == "flc", flacVariant != .original,
              !unavailable.contains("\(server ?? "")|\(flacVariant.rawValue)") else { return .original }
        return flacVariant
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

    private func fileName(for track: Track) -> String { fileName(for: track.id, variant: variant(for: track)) }
    private func fileName(for id: String, variant: Variant) -> String {
        variant == .original ? "\(id).audio" : "\(id).\(variant.rawValue).audio"
    }
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
        let saved = SavedPlan(tracks: plan, streamFormat: streamFormat,
                              replayGainApplied: replayGainApplied, server: server,
                              flacVariant: flacVariant.rawValue)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.planFileName), options: .atomic)
    }

    private func loadPlan() {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.planFileName)),
              let saved = try? JSONDecoder().decode(SavedPlan.self, from: data) else { return }
        plan = saved.tracks
        streamFormat = saved.streamFormat
        replayGainApplied = saved.replayGainApplied
        server = saved.server
        flacVariant = saved.flacVariant.flatMap(Variant.init(rawValue:)) ?? .original
        os_log(.info, log: logger, "🛟 Loaded saved plan: %d tracks (FLAC as %{public}s)", plan.count, flacVariant.name)
    }

    private func hasFile(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName(for: track)).path)
    }

    /// Smaller than any real copy of `duration` seconds (16 kbit/s): an empty
    /// or cut-off answer (a pass-through rule that outputs nothing, a
    /// transcoder that died) mustn't count as a copy.
    static func isImplausiblySmall(bytes: Int64, duration: Double) -> Bool {
        bytes < max(16_000, Int64(duration * 2_000))
    }

    private func directorySize() -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(Int64(0)) { sum, name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return sum + ((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Suspend or resume the downloads (a suspended URLSession task moves no
    /// bytes and has no timeout; it goes on from where it was).
    func holdDownloads(_ hold: Bool) {
        guard hold != downloadsHeld else { return }
        downloadsHeld = hold
        if hold {
            active?.suspend()
        } else {
            active?.resume()
            downloadNext()
        }
    }

    private func downloadNext() {
        guard active == nil, !queue.isEmpty, !downloadsHeld else { return }
        guard mayDownload() else {
            os_log(.info, log: logger, "🛟 Not downloading now (metered network)")
            return
        }
        guard directorySize() < Self.maxBytes else {
            os_log(.info, log: logger, "🛟 Cache full (%lld MB) - not downloading more", directorySize() / 1_048_576)
            return
        }
        let track = queue.removeFirst()
        let usedVariant = variant(for: track)
        let path = "/music/\(track.id)/download\(usedVariant.urlSuffix)"
        guard let url = URL(string: settings.buildURLString(path: path)) else { return }
        var request = URLRequest(url: url)
        request.allowsExpensiveNetworkAccess = allowExpensive
        request.setValue(settings.customUserAgent, forHTTPHeaderField: "User-Agent")
        if let auth = settings.generateAuthHeader() {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        let started = Date()
        let usedServer = server ?? ""
        activeID = track.id
        let task = URLSession.lms.downloadTask(with: request) { [weak self] location, response, error in
            // Move the file before returning: the temporary one is deleted afterwards.
            var stored: URL?
            var status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let location = location, error == nil, status == 200 || status == 206, let self = self {
                let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? 0
                guard !Self.isImplausiblySmall(bytes: size, duration: track.duration) else {
                    DispatchQueue.main.async {
                        guard self.activeID == track.id else { return }
                        os_log(.error, log: self.logger, "🛟 Download of track %{public}s too short (%lld bytes for %.0fs) - not kept",
                               track.id, size, track.duration)
                        self.active = nil
                        self.activeID = nil
                        self.failed.insert("\(track.id)|\(usedVariant.rawValue)")
                        self.downloadNext()
                    }
                    return
                }
                let dest = self.directory.appendingPathComponent(self.fileName(for: track.id, variant: usedVariant))
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
                    // FLAC files only ask for a transcode, so this is the server's rule missing.
                    os_log(.info, log: self.logger, "🛟 Server has no %{public}s download rule - using original files",
                           usedVariant.name)
                    self.unavailable.insert("\(usedServer)|\(usedVariant.rawValue)")
                    self.queue.insert(track, at: 0)
                } else {
                    os_log(.error, log: self.logger, "🛟 Download of track %{public}s failed (HTTP %d, %{public}s)",
                           track.id, status, error?.localizedDescription ?? "-")
                    if status >= 400 { self.failed.insert("\(track.id)|\(usedVariant.rawValue)") }
                }
                self.downloadNext()
            }
        }
        active = task
        task.resume()
    }
}
