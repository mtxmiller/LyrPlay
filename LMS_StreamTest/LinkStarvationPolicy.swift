// File: LinkStarvationPolicy.swift
// Two decisions for a slow link (cellular in a car, device log 2026-10-24),
// kept pure so they can be unit-tested.
//
// A user pause used to be only a JSON-RPC round trip: nothing happened on the
// phone until LMS answered with strm 'p'. On a starved link that reply is late,
// and LMS drops a Pause outright while the player is BUFFERING
// (StreamingController.pm state table: Pause × BUFFERING → _NoOp), which is
// exactly when a listener hearing silence presses it. So the phone pauses at
// once and the unpause LMS sends when its buffer fills is held until the pause
// has been re-sent and confirmed (bd LMS_StreamTest-jbbf).
//
// When the output buffer runs dry mid-track with the download still open,
// squeezelite reports STMo (slimproto.c: output empty, stream STREAMING_HTTP)
// and LMS rebuffers: pause, refill, resume. LyrPlay let BASS play each
// fragment as it arrived, which the listener hears as chopping (bd tes3).
import Foundation

enum UserPausePolicy {
    /// Pause the engine on the phone now? Only when audio is ours to stop:
    /// playing, or stalled waiting for data ("Buffering"). Already paused
    /// (LMS rebuffering, an earlier pause) or no stream: nothing to do locally.
    static func pausesLocally(playerState: String) -> Bool {
        playerState == "Playing" || playerState == "Buffering"
    }

    /// A strm 'u' while the user's pause is unconfirmed: LMS dropped the pause
    /// (it ignores Pause while BUFFERING) or it is still in flight. Hold the
    /// unpause and send the pause again, a bounded number of times.
    static func holdsUnpause(pendingSince: Date?, now: Date, window: TimeInterval,
                             resends: Int, maxResends: Int) -> Bool {
        guard let since = pendingSince, now.timeIntervalSince(since) < window else { return false }
        return resends < maxResends
    }

    /// The status poll says LMS is still playing a while after the user's
    /// pause: the request or its reply was lost on the link. Send it again.
    static func resendsOnPoll(pendingSince: Date?, now: Date, serverMode: String?,
                              minimumAge: TimeInterval, resends: Int, maxResends: Int) -> Bool {
        guard let since = pendingSince, serverMode == "play",
              now.timeIntervalSince(since) >= minimumAge else { return false }
        return resends < maxResends
    }
}

enum OutputUnderrunPolicy {
    /// LMS gives up a rebuffer after 30 s and restarts the song; a link that
    /// keeps running dry gets this many rebuffers per song before we fall back
    /// to playing fragments as they come (squeezelite reports once per song).
    static let maxReportsPerStream = 6

    /// Report STMo for this drain? Only a stall of the server's own stream
    /// while its download is still open: a drained saved copy, a cut download
    /// (another path recovers it), a finished decode (STMu's case), a strm
    /// still being decided, or a report LMS has not answered yet (BASS can
    /// stall again before the 'p' arrives) are not new underruns.
    static func reports(playerState: String, downloadOpen: Bool, decodeComplete: Bool,
                        playingCopy: Bool, deciding: Bool, serverConnected: Bool,
                        awaitingServer: Bool, reportsSoFar: Int) -> Bool {
        // The STALL sync fires only for a channel that was playing; a trickle of
        // data may have it "Playing" again by the time we look. Paused or
        // stopped, the drain was asked for.
        guard playerState == "Buffering" || playerState == "Playing" else { return false }
        guard downloadOpen, !decodeComplete, !playingCopy, !deciding, serverConnected, !awaitingServer else { return false }
        return reportsSoFar < maxReportsPerStream
    }

    /// The strm 'p' that follows our STMo is LMS rebuffering, not a pause the
    /// user asked for: in the listener's eyes we are still playing.
    static func pauseIsRebuffer(reportedAt: Date?, now: Date, window: TimeInterval = 3) -> Bool {
        guard let at = reportedAt else { return false }
        return now.timeIntervalSince(at) < window
    }
}

/// The saved copies download over the same link as the stream, at the same
/// bitrate, so on a thin link the first song competes with its own copy and
/// the next songs' (bd LMS_StreamTest-xrvg). While the stream is behind, the
/// downloads wait; they go on once the output queue is comfortably full.
/// Checked once a second (SlimProtoCoordinator's lifeboat watch).
enum DownloadHoldPolicy {
    /// Under this much decoded audio queued for output, the stream is behind.
    /// On a fast link the queue passes it within a second of a song's start.
    static let holdBelow: TimeInterval = 15
    /// Above this the link has room again. The queue holds about 30 s
    /// (AudioStreamDecoder.maxBufferSize), so a healthy stream always gets here.
    static let releaseAbove: TimeInterval = 25

    /// Hold (or keep holding) the downloads this second? Only a network stream
    /// still downloading needs the link: a saved copy playing, a download
    /// that has ended, or a decode that finished (the whole song is on the
    /// phone) frees it. LMS rebuffering us is the stream behind by definition,
    /// whatever the engine's state; a pause the user asked for drains nothing,
    /// so the downloads may use the idle link.
    static func holds(holding: Bool, playerState: String, downloadOpen: Bool, decodeComplete: Bool,
                      playingCopy: Bool, rebuffering: Bool, bufferedSeconds: Double) -> Bool {
        guard !playingCopy, downloadOpen, !decodeComplete else { return false }
        if rebuffering { return true }
        guard playerState == "Playing" || playerState == "Buffering" else { return false }
        return bufferedSeconds < (holding ? releaseAbove : holdBelow)
    }
}
