// File: CopyPlaybackDecision.swift
// Play saved songs from the file when LMS asks for them (bd 5syr). At every
// strm 's', a complete saved copy of the song LMS wants is played instead of
// its stream; LMS stays in charge and gets the same STAT events as for a
// stream. The strm itself names no song and no start time, so the song comes
// from a fresh `status` and from what we asked for (our STMd, our jump).
// Pure: SlimProtoCoordinator gathers the facts, this decides.
import Foundation

enum CopyPlaybackDecision: Equatable {
    /// Play the saved copy of the song at this playlist index, from its start.
    case file(index: Int)
    /// LMS restarted the song we are playing from a copy, where we asked it
    /// to (our reconnect jump): keep playing, no flush, no stream.
    case handback(startOffset: Double)
    /// Open LMS's stream, as before. The reason is for the log.
    case stream(String)

    /// A complete saved copy: the song's id and the strm formats it is the
    /// same audio as (an Opus copy for an Opus stream, an MP3 original for MP3).
    struct SavedCopy: Equatable {
        let id: String
        let formats: Set<String>
    }

    /// The song a saved copy is playing now (`position` in song seconds).
    struct PlayingCopy: Equatable {
        let id: String
        let position: Double
    }

    /// Our reconnect jump: LMS was asked to play song `id` at `index` from `offset`.
    struct ExpectedHandback: Equatable {
        let index: Int
        let id: String
        let offset: Double
    }

    /// LMS's answer to `status - 2` right after the strm.
    struct ServerState: Equatable {
        var index: Int?
        var tracks: Int
        /// 0 off, 1 song, 2 all.
        var repeatMode: Int
        /// LMS's elapsed time. Asked while our STATs report 0 elapsed, it is the
        /// strm's start offset (StreamingController playingSongElapsed =
        /// start offset + the player's elapsed).
        var time: Double?
        var duration: Double?
        var remote: Bool
        /// Track ids by playlist index, from the status loop.
        var ids: [Int: String]
    }

    /// LMS starts at the offset we sent (a few ms off after a native seek).
    static let handbackTolerance: Double = 3
    /// Our playhead may run ahead of the jump's offset by the time the jump
    /// took to go out (the recovery waits up to 10 s for the server).
    static let handbackMaxLead: Double = 15
    /// Below this LMS starts the song from its start.
    static let startTolerance: Double = 1.5

    /// - Parameters:
    ///   - enabled: the setting is on and we are not in a sync group.
    ///   - sameServer: the copies came from the server we are connected to.
    ///   - afterDecodeEnd: this strm answers our STMd (the next song, gaplessly).
    ///   - afterDecodeError: an STMn went out since the last strm (LMS skips ahead
    ///     from the failed song, not from the playing one).
    static func decide(strmFormat: String, enabled: Bool, sameServer: Bool,
                       afterDecodeEnd: Bool, afterDecodeError: Bool,
                       server: ServerState, copies: [Int: SavedCopy],
                       playing: PlayingCopy?, handback: ExpectedHandback?) -> CopyPlaybackDecision {
        guard enabled else { return .stream("saved copies off or in a sync group") }
        guard sameServer else { return .stream("the copies are from another server") }
        guard !server.remote else { return .stream("radio or a streaming service") }
        guard !afterDecodeError else { return .stream("after a decode error") }
        guard let current = server.index, server.tracks > 0 else { return .stream("no status") }

        if afterDecodeEnd {
            guard let next = nextIndex(after: current, tracks: server.tracks, repeatMode: server.repeatMode) else {
                return .stream("end of the playlist")
            }
            return fileIfSaved(next, strmFormat: strmFormat, server: server, copies: copies)
        }

        // Our reconnect jump, for the song a copy is still playing.
        if let expected = handback, expected.index == current, server.ids[current] == expected.id,
           let playing = playing, playing.id == expected.id {
            guard let start = server.time, abs(start - expected.offset) <= handbackTolerance else {
                return .stream("LMS did not start where we moved it")
            }
            guard playing.position >= start - handbackTolerance,
                  playing.position <= start + handbackMaxLead else {
                return .stream("the copy is not playing near the jump")
            }
            return .handback(startOffset: start)
        }

        // Anything else must start at the beginning of the song: LMS reported
        // the start offset clipped to the duration, so a time at the very end is no proof.
        guard let start = server.time, start <= startTolerance,
              server.duration.map({ start < $0 - 0.5 }) ?? true else {
            return .stream("starts mid-song (a seek or a jump)")
        }
        return fileIfSaved(current, strmFormat: strmFormat, server: server, copies: copies)
    }

    /// The song LMS plays after `index` (shuffle is already the play order).
    static func nextIndex(after index: Int, tracks: Int, repeatMode: Int) -> Int? {
        if repeatMode == 1 { return index }
        if index + 1 < tracks { return index + 1 }
        return repeatMode == 2 ? 0 : nil
    }

    private static func fileIfSaved(_ index: Int, strmFormat: String, server: ServerState,
                                    copies: [Int: SavedCopy]) -> CopyPlaybackDecision {
        guard let copy = copies[index] else { return .stream("no complete copy of track \(index)") }
        guard server.ids[index] == copy.id else { return .stream("track \(index) is not the saved song") }
        guard copy.formats.contains(strmFormat) else {
            return .stream("the copy of track \(index) is not \(strmFormat)")
        }
        return .file(index: index)
    }
}
