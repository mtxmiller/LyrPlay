# Gapless Playback Assessment and Plan

## Current Playback Flow (LyrPlay)
- `SlimProtoCoordinator.didStartStream` stops the active channel before creating the next one, so every track transition starts from silence (`LMS_StreamTest/SlimProtoCoordinator.swift:857`).
- `AudioPlayer.playStream` reinitialises a single `HSTREAM` per track with no secondary buffer or mixer, so BASS has no object to pre-roll the upcoming audio (`LMS_StreamTest/AudioPlayer.swift:210`).
- Track completion is detected from a `BASS_SYNC_END` callback and immediately reported as decoder-ready (`SlimProtoCommandHandler.notifyTrackEnded`), leaving no tail window where audio plays while the next stream is prepared (`LMS_StreamTest/SlimProtoCommandHandler.swift:509`).
- SlimProto fields such as `autostart`, `threshold`, and transition hints are parsed but dropped, so the client cannot follow LMS' direct-stream/gapless choreography (`LMS_StreamTest/SlimProtoCommandHandler.swift:175`).
- The advertised capability string never states gapless readiness, which keeps LMS in its conservative start/stop scheduling mode (`LMS_StreamTest/SettingsManager.swift:137`).

## Observed Gapless Blocking Issues
- We tear down the output device before the server issues the next `strm`, so T+network RTT always inserts silence.
- Ignored `autostart` values mean we never wait for `cont` notifications or buffer thresholds that LMS uses to overlap decoding, breaking the server's prefetch logic (`LMS_StreamTest/SlimProtoCommandHandler.swift:175`).
- There is no concept of `queuedStream` or mixer; when a new track arrives we either replace `currentStream` synchronously or restart playback, so BASS cannot cross the zero-crossing safely (`LMS_StreamTest/AudioPlayer.swift:220`).
- Status packets (`STMd`, `STMs`, `STMu`) are emitted strictly on BASS state changes, not on buffer state, so LMS cannot pipeline the next track while audio drains (`LMS_StreamTest/SlimProtoCoordinator.swift:853`).
- We do not account for codec encoder padding/trim data, so even if we perfectly overlap tracks we would expose residual silence for MP3/AAC/ALAC edges.

## Reference Behaviour (Squeezelite & LMS)
- Squeezelite preserves the current decoder output while flagging the start of the next track with `output.track_start`, allowing the mixer to swap buffers atomically when playback reaches the marker (`/Users/ericmiller/Downloads/squeezelite/output.c:126`).
- Each decoder writes its first sample position into the shared ring buffer, so the output thread knows where the seamless boundary lives (`/Users/ericmiller/Downloads/squeezelite/pcm.c:216`).
- The controller sends `STMd` as soon as decode is complete—even while audio is still flushing—so LMS can dispatch the following `strm` without audible interruption (`/Users/ericmiller/Downloads/squeezelite/slimproto.c:684`).
- LMS only stays in gapless mode when consecutive tracks share compatible formats; the logic lives in `isReadyToStream`, and it expects the client to honour sample-rate and channel continuity (`/Users/ericmiller/Downloads/slimserver/Slim/Player/Squeezebox1.pm:132`).
- LMS sets `autostart >= 2` for direct/gapless streams and relies on the client to honour `cont` pacing and local thresholds before switching output (`/Users/ericmiller/Downloads/slimserver/Slim/Player/Squeezebox.pm:804`).

## Proposed Architecture Changes
- Introduce a dedicated `GaplessPlaybackController` that owns a BASS mixer output, the live stream, and an optional queued stream, replacing direct `AudioPlayer` play/stop calls.
- Extend `SlimProtoCommandHandler` to track `autostart`, `threshold`, transition type, and pass structured playback instructions to the controller instead of discarding them.
- Delay `STMd` until PCM for the current track is drained from the mixer (but before silence), mirroring squeezelite's "decode complete while output busy" model.
- Capture codec padding metadata (e.g., via LMS `status` tags or HTTP headers) and configure BASS channel offsets so MP3/AAC/ALAC boundaries are sample-accurate.
- Advertise gapless capability in the HELO string only after the new pipeline can respect LMS' expectations.

## Implementation Plan
1. **Instrumentation & Capability Audit** – Log `autostart`, thresholds, and server transition flags; add metrics for BASS buffer depth and verify LMS sees the new capability knobs.
2. **SlimProto Handling Upgrade** – Model `SlimProtoStreamDirective` with autostart/threshold fields, handle `cont`, and stop forcing `audioManager.stop()` on every `didStartStream`.
3. **Gapless Mixer Prototype** – Wrap `AudioPlayer` around a `BASS_Mixer_StreamCreate` output, keep the current channel live, and queue the next `HSTREAM` using `BASS_Mixer_StreamAddChannelEx` when we receive a compatible `strm`.
4. **Codec Boundary Accuracy** – Use LMS metadata (`status tags: k,a,d`) or ICY headers to configure per-track trim on the queued channel before it enters the mixer; add regression logs to confirm measured overlap.
5. **Status & Recovery Alignment** – Re-time `STMs`, `STMd`, and underrun (`STMu`) events based on mixer state; update recovery helpers to work with mixer-managed seeks and ensure lock-screen commands still resolve.
6. **Verification** – Build automated track-sequence tests (lossless and lossy) plus manual scenarios (seek mid-track, pause/resume, CarPlay route change) to confirm no audible clicks and identical server playlist timing.

## Risks & Open Questions
- BASS' mixer API must handle HTTP network streams without large latency; if it cannot, we may need custom decode pipelines akin to squeezelite.
- LMS only enables gapless when formats match; we need a policy for mixed playlists (fallback to legacy behaviour or force server transcoding).
- Accurate encoder padding data might be unavailable for radio streams; decide whether to skip gapless for live sources or measure latency heuristically.
- Mobile backgrounding could tear down queued streams; we need to validate mixer resilience when iOS suspends network tasks.
- Additional buffering may increase memory use on older devices; monitor with Instruments and expose developer settings if needed.
