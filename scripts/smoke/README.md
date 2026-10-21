# Playback Smoke-Test Harness — LMS Server as Test Oracle

**Status**: v0 implemented (this directory). bd epic `LMS_StreamTest-6b1`; v1
(OSLog correlation) and v2 (lifecycle/device scenarios) tracked as children.

## Why

Manual listening is the verification bottleneck for this project. But LyrPlay is a
SlimProto client of an *observable server*: nearly every playback behavior is mirrored
in LMS state that is queryable over JSON-RPC. A healthy audio pipeline shows up as
machine-checkable signals — no ears, no audio capture:

- the player is registered and `connected`
- `mode` is `play`
- `time` advances monotonically at ~1x wall clock
- `playlist_cur_index` changes at the expected track boundary, not early or late

Historical shipped bugs map directly onto these signals:

| Bug class | Oracle signal that catches it |
|---|---|
| Gapless early-jump (LMS_StreamTest-sfk) | index advances tens of seconds before the boundary |
| Silent playback after interruption (u7h) | `mode == play` but `time` frozen (stall watchdog) |
| Recovery lands at wrong track/position | post-recovery `playlist_cur_index`/`time` ≠ saved values (v2) |
| Player never reconnects | player absent from `serverstatus.players_loop` |

What the oracle **cannot** catch: audible glitches (clicks at gapless seams, 100ms
audio bursts), CarPlay hardware behavior, real phone-call interruptions. Those stay
human-verified.

## Usage

```bash
scripts/smoke/run.sh             # build, boot sim, launch app, all scenarios
scripts/smoke/run.sh S1 S5       # a subset
python3 scripts/smoke/smoke.py   # scenarios only (app already running)
```

`run.sh` builds the iOS app (incremental, cached DerivedData in
`~/Library/Developer/Xcode/DerivedData/LyrPlay-smoke` — deliberately outside the
repo: the repo lives under `Documents/`, where iCloud's Finder metadata breaks
codesign), boots the simulator, pre-seeds UserDefaults so the app launches
already configured against the test server, and runs the scenarios. Exit
nonzero on any failure.

The defaults point at the `lms-test` server on ser5 (web 9010, SlimProto 3490; demo library), so test players never land on the production LMS.

Env knobs (defaults): `LYRPLAY_LMS_HOST` (192.168.1.8), `LYRPLAY_LMS_PORT`
(9010), `LYRPLAY_SLIM_PORT` (3490), `LYRPLAY_SIM_NAME` (iPhone 17),
`LYRPLAY_PLAYER_NAME` (SmokeTest Player), `LYRPLAY_PLAYER_ID` (skips
discovery), `LYRPLAY_SOAK_SECONDS` (60), `LYRPLAY_APP_PATH` (prebuilt .app,
skips the build).

## Scenarios — v0

Test content is selected from the server library at run time (no hardcoded
IDs): an album with ≥ 2 tracks, an opening track of 20–300s (true track order
via `sort:tracknum`), and at least one track ≥ 45s for the seek proof.

| ID | Scenario | Pass criteria |
|---|---|---|
| S1 | register & play | player discovered by name ≤ 30s; album loads; mode=play; time advancing at 1x ±0.15 after buffering settles |
| S2 | pause/resume | time frozen (±0.5s over 3s) while paused; single post-resume sample within [-0.5, +4.0]s of the pause position (catches restart-at-0; pause taken ≥ 5s in so the cases are distinguishable) |
| S3 | skip next/prev | index +1 with time restarting < 3s; index -1; advancing after |
| S4 | seek | **provable** forward jump: +25s from the playhead on a ≥ 45s track — bigger than natural playback can sweep within the 8s poll window, so a matched position proves the seek |
| S5 | gapless boundary | seek to duration−15 on track 0; index 0→1 within an effective **−4s/+10s** window of the boundary (tighter risks false fails from LMS server-side time interpolation; the sfk class fires ~30s early and is caught decisively); next track advancing after |
| S6 | stall soak | 60s (configurable) of mode=play with time at ~1x; track boundaries mid-window tolerated (bounded re-measure, max 3) |

Notes on intent vs. mechanics:

- **Stall watchdog** is not a background thread; it's `assert_time_advancing`,
  called explicitly in every scenario. A stall during an index-wait surfaces
  as that scenario's timeout instead.
- Scenarios share player state (the loaded album) for speed; `ensure_playing`
  re-establishes the baseline so any subset is still runnable.
- `wait_until_advancing` separates re-buffering after loads/jumps/seeks from
  genuine stalls — without it, the first measurement window after any stream
  restart reads ~0.5x and false-fails.

## Architecture

```
run.sh   — build (always; stale binaries must never get certified),
           boot sim (newest runtime for the device name),
           pre-seed UserDefaults (keys/types match SettingsManager.Keys),
           install + launch, then exec smoke.py
smoke.py — Oracle (JSON-RPC client + assertion vocabulary),
           pick_album (runtime test-content selection),
           scenarios S1–S6, pass/fail table, exit code
```

Python 3 stdlib only; no new dependencies.

## Outage scenarios (O1–O25)

Network drops and offline playback (saved copies). `faultproxy.py` runs on
the host next to the test LMS and sits between the app and LMS: it freezes,
refuses, cuts or throttles the app's connections while the oracle talks to
LMS directly. `outage.py` holds the scenarios; its docstring has the table of
outages and pass criteria, `faultproxy.py`'s the control API (`:9099`).

```bash
export LYRPLAY_APP_WEB_PORT=9011 LYRPLAY_APP_SLIM_PORT=3491   # the app goes through the proxy
LYRPLAY_LAUNCH_ARGS="-Lifeboat 2" scripts/smoke/run.sh        # build + smoke S1–S6
LYRPLAY_LIFEBOAT=1 python3 scripts/smoke/outage.py O1 O2 O3 O4 O6 O7 O8 O9 O10 O11 O12 O13 O14 O15 O16 O17 O18 O19 O20 O21 O22 O23 O24 O25
```

O5 (320 s) runs only when named. O25 needs a queue that mixes FLAC and MP3
songs: `LYRPLAY_MIXED_TRACKS=11,130,12,131,13,132` on the test LMS. Stream format for a run:
`-AudioFormat <integer>0</integer>` (MP3) or `<integer>2</integer>` (Opus);
the test LMS needs `prioritizeNative 0` for an Opus stream. The full run
takes about 2 hours. Design: wiki `Architecture/Offline Playback.md`.

## Roadmap

- **v1 — log correlation** (`LMS_StreamTest-6b1.2`): stream OSLog (subsystem
  `com.lmsstream`) during scenarios; dump tail on failure; assert no
  error-level audio logs during passing scenarios.
- **v2 — lifecycle & device** (`LMS_StreamTest-6b1.3`): background >45s
  recovery, route change, interruption. Simulator can background the app;
  lock screen and real interruptions need a USB device (wiki:
  `Setup/iPhone Build Workflow.md`). Recovery assertions: post-recovery
  `playlist_cur_index`/`time` match saved pre-background values
  (`performPlaylistRecovery()` end-to-end).
