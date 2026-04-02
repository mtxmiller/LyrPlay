// File: GaplessDiagnostics.swift
// Auto-logging ring buffer for gapless transition diagnostics
import Foundation

/// Records timing and buffer data for every gapless transition.
/// Ring buffer holds last 20 transitions. Export via Settings when needed.
class GaplessDiagnostics {
    static let shared = GaplessDiagnostics()

    private let queue = DispatchQueue(label: "com.lmsstream.gapless-diag")
    private let maxTransitions = 20

    private var transitions: [TransitionRecord] = []
    private var current: TransitionRecord?

    // MARK: - Data Structures

    struct BufferSnapshot {
        let playbackBuffer: Int      // BASS_DATA_AVAILABLE (bytes)
        let queueSize: Int           // BASS_StreamPutData(nil, 0) (bytes)
        let playbackPosition: UInt64 // BASS_ChannelGetPosition (bytes)
        let sampleRate: Int
        let channels: Int

        var totalBuffered: Int { playbackBuffer + queueSize }

        var secondsRemaining: Double {
            let bytesPerSecond = sampleRate * channels * 4 // float32
            guard bytesPerSecond > 0 else { return 0 }
            return Double(totalBuffered) / Double(bytesPerSecond)
        }

        var formatted: String {
            let pbKB = playbackBuffer / 1024
            let qKB = queueSize / 1024
            let totalKB = totalBuffered / 1024
            return "playback=\(pbKB)KB, queue=\(qKB)KB, total=\(totalKB)KB (\(String(format: "%.1f", secondsRemaining))s)"
        }
    }

    struct TransitionEvent {
        let name: String
        let timestamp: Date
        let buffer: BufferSnapshot?
        let extra: String?
    }

    struct TransitionRecord {
        let id: Int
        let startTime: Date
        var events: [TransitionEvent] = []

        var stmdTime: Date? { events.first(where: { $0.name == "STMd" })?.timestamp }
        var stmsTime: Date? { events.first(where: { $0.name == "STMs" })?.timestamp }

        var totalGapSeconds: Double? {
            guard let stmd = stmdTime, let stms = stmsTime else { return nil }
            return stms.timeIntervalSince(stmd)
        }
    }

    private var nextId = 1

    private init() {}

    // MARK: - Recording Events

    /// Call when STMd is sent (decoder finished, track decode complete)
    func recordDecodeComplete(buffer: BufferSnapshot) {
        queue.sync {
            let record = TransitionRecord(id: nextId, startTime: Date())
            nextId += 1
            current = record
            appendEvent(name: "STMd", buffer: buffer, extra: nil)
        }
    }

    /// Call when gapless STRM arrives (server queued next track)
    func recordGaplessSTRM(buffer: BufferSnapshot) {
        queue.sync {
            appendEvent(name: "STRM(gapless)", buffer: buffer, extra: nil)
        }
    }

    /// Call when track boundary is marked in AudioStreamDecoder
    func recordBoundaryMarked(buffer: BufferSnapshot, boundaryPosition: UInt64, secondsUntilBoundary: Double) {
        queue.sync {
            let extra = "boundary=\(boundaryPosition), eta=\(String(format: "%.1f", secondsUntilBoundary))s"
            appendEvent(name: "Boundary marked", buffer: buffer, extra: extra)
        }
    }

    /// Call when STMs is sent (track boundary reached, audio transition happened)
    func recordTrackStarted(buffer: BufferSnapshot) {
        queue.sync {
            appendEvent(name: "STMs", buffer: buffer, extra: nil)
            finalizeCurrentTransition()
        }
    }

    private func appendEvent(name: String, buffer: BufferSnapshot?, extra: String?) {
        guard current != nil else { return }
        current!.events.append(TransitionEvent(
            name: name,
            timestamp: Date(),
            buffer: buffer,
            extra: extra
        ))
    }

    private func finalizeCurrentTransition() {
        guard let record = current else { return }
        transitions.append(record)
        if transitions.count > maxTransitions {
            transitions.removeFirst()
        }
        current = nil
    }

    // MARK: - Export

    func formattedLog() -> String {
        queue.sync {
            if transitions.isEmpty && current == nil {
                return "No gapless transitions recorded yet."
            }

            var lines: [String] = []
            lines.append("=== LyrPlay Gapless Diagnostics ===")
            lines.append("Exported: \(formatDate(Date()))")
            lines.append("")

            let all = current != nil ? transitions + [current!] : transitions
            for record in all {
                let gap = record.totalGapSeconds.map { String(format: "%.1fs", $0) } ?? "in progress"
                lines.append("Transition #\(record.id) — \(formatDate(record.startTime)) — gap: \(gap)")

                for event in record.events {
                    let offset = event.timestamp.timeIntervalSince(record.startTime)
                    var line = "  +\(String(format: "%06.3f", offset))s  \(event.name)"
                    if let buf = event.buffer {
                        line += "  \(buf.formatted)"
                    }
                    if let extra = event.extra {
                        line += "  [\(extra)]"
                    }
                    lines.append(line)
                }
                lines.append("")
            }

            lines.append("Total transitions: \(all.count)")
            return lines.joined(separator: "\n")
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
