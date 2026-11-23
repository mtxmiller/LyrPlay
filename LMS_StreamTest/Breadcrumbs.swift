// File: Breadcrumbs.swift
// A small file of app state changes that survives a force-quit. The diagnostic
// log reads OSLogStore, which on iOS only returns the current process, so the
// run a user force-quits is lost (bd f9r0). Each launch moves the last file to
// "previous" and starts a new one; the log export includes both.

import Foundation
import os.log

enum Breadcrumbs {
    private static let queue = DispatchQueue(label: "com.lyrplay.breadcrumbs", qos: .utility)
    private static let maxBytes = 256 * 1024
    private static let logger = OSLog(subsystem: "com.lmsstream", category: "Breadcrumbs")

    private static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Breadcrumbs", isDirectory: true)
    }
    private static var currentURL: URL? { directory?.appendingPathComponent("current.log") }
    private static var previousURL: URL? { directory?.appendingPathComponent("previous.log") }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Once per launch, before the first note.
    static func startLaunch(_ header: String) {
        queue.async {
            guard let dir = directory, let current = currentURL, let previous = previousURL else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: current.path) {
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: current, to: previous)
            }
            write("=== \(header) ===")
        }
    }

    static func note(_ text: String) {
        let stamp = Date()
        queue.async { write("\(formatter.string(from: stamp)) \(text)") }
    }

    /// The previous launch's notes (nil if none), for the diagnostic log export.
    static func previousLaunch() -> String? {
        queue.sync {
            guard let url = previousURL else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// This launch's notes.
    static func currentLaunch() -> String? {
        queue.sync {
            guard let url = currentURL else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    // Runs on `queue`.
    private static func write(_ line: String) {
        guard let url = currentURL, let data = (line + "\n").data(using: .utf8) else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
            // Keep the newest half: the end of a run is what explains a force-quit.
            // Cut after a line break so no line (or UTF-8 character) is split.
            if let old = try? Data(contentsOf: url) {
                var tail = old.suffix(maxBytes / 2)
                if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
                    tail = tail[tail.index(after: newline)...]
                }
                try? Data(tail).write(to: url)
            }
        }
        if !fm.fileExists(atPath: url.path) {
            do { try data.write(to: url) } catch {
                os_log(.error, log: logger, "Breadcrumb write failed: %{public}s", error.localizedDescription)
            }
            return
        }
        // Append only: never replace an existing file (it may just be unreadable
        // for now, e.g. before the first unlock after a restart).
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
