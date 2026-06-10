#!/usr/bin/env python3
"""LyrPlay playback smoke harness — LMS server as test oracle (v0).

Spec: scripts/smoke/README.md (bd epic LMS_StreamTest-6b1).

Asserts playback health from LMS JSON-RPC state alone: player registered,
mode, time advancing at ~1x wall clock, playlist index changing at expected
track boundaries. No audio capture — audible quality stays human-verified.

Usually invoked via scripts/smoke/run.sh (which boots the simulator and
launches a preconfigured app). Run directly when the app is already up:

    python3 scripts/smoke/smoke.py            # all scenarios
    python3 scripts/smoke/smoke.py S1 S5      # a subset

Env:
    LYRPLAY_LMS_HOST      LMS host (default 192.168.1.8)
    LYRPLAY_LMS_PORT      LMS HTTP port (default 9000)
    LYRPLAY_PLAYER_NAME   player name to discover (default "SmokeTest Player")
    LYRPLAY_PLAYER_ID     player MAC — skips name discovery
    LYRPLAY_SOAK_SECONDS  S6 soak duration (default 60)

Exit code 0 = all selected scenarios passed.
"""

import json
import os
import sys
import time
import urllib.request

LMS_HOST = os.environ.get("LYRPLAY_LMS_HOST", "192.168.1.8")
LMS_PORT = int(os.environ.get("LYRPLAY_LMS_PORT", "9000"))
PLAYER_NAME = os.environ.get("LYRPLAY_PLAYER_NAME", "SmokeTest Player")
PLAYER_ID = os.environ.get("LYRPLAY_PLAYER_ID", "")
SOAK_SECONDS = int(os.environ.get("LYRPLAY_SOAK_SECONDS", "60"))

POLL_INTERVAL = 0.5


class CheckFailed(Exception):
    pass


class Oracle:
    """Minimal JSON-RPC client for LMS + the assertion vocabulary from the spec."""

    def __init__(self, host, port):
        self.url = f"http://{host}:{port}/jsonrpc.js"
        self.player_id = PLAYER_ID

    def rpc(self, cmd, player=""):
        body = json.dumps(
            {"id": 1, "method": "slim.request", "params": [player, cmd]}
        ).encode()
        req = urllib.request.Request(
            self.url, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.load(resp).get("result", {})

    def player_rpc(self, cmd):
        return self.rpc(cmd, player=self.player_id)

    # -- discovery ---------------------------------------------------------

    def discover(self, name, timeout=30):
        """Find the player by name in serverstatus; sets self.player_id.
        Transient network errors consume the timeout budget instead of crashing."""
        deadline = time.time() + timeout
        seen, last_err = [], None
        while time.time() < deadline:
            try:
                players = self.rpc(["serverstatus", 0, 99]).get("players_loop", [])
            except OSError as e:
                last_err = e
                time.sleep(1)
                continue
            seen = [(p.get("name"), p.get("playerid"), p.get("connected")) for p in players]
            for p in players:
                if p.get("name") == name and p.get("connected"):
                    self.player_id = p["playerid"]
                    return self.player_id
            time.sleep(1)
        raise CheckFailed(
            f"player named {name!r} not connected within {timeout}s; "
            f"saw: {seen}" + (f"; last error: {last_err}" if last_err else "")
        )

    # -- state -------------------------------------------------------------

    def status(self):
        """mode / time / duration / playlist index / track count, one query."""
        r = self.player_rpc(["status", "-", 1, "tags:d"])
        return {
            "mode": r.get("mode", "?"),
            "time": float(r.get("time", 0) or 0),
            "duration": float(r.get("duration", 0) or 0),
            "index": int(r.get("playlist_cur_index", -1)),
            "tracks": int(r.get("playlist_tracks", 0)),
        }

    def playlist_durations(self):
        """Per-track durations of the loaded playlist, in true playlist order."""
        loop = self.player_rpc(["status", 0, 99, "tags:d"]).get("playlist_loop", [])
        return [float(t.get("duration", 0) or 0) for t in loop]

    # -- assertions (spec: scripts/smoke/README.md) --------------------------

    def assert_mode(self, expected):
        mode = self.status()["mode"]
        if mode != expected:
            raise CheckFailed(f"mode is {mode!r}, expected {expected!r}")

    def assert_time_advancing(self, window=5.0, lo=0.85, hi=1.15, _retries=3):
        """time must advance at ~1x wall clock over the window. Doubles as the
        stall watchdog: mode==play with frozen time fails here (u7h class)."""
        for attempt in range(_retries):
            s0, w0 = self.status(), time.time()
            time.sleep(window)
            s1, w1 = self.status(), time.time()
            rate = (s1["time"] - s0["time"]) / (w1 - w0)
            if lo <= rate <= hi:
                return
            # A track boundary inside the window resets time — measure again
            # (bounded; a stalled player has a stable index and fails below).
            if rate < lo and s1["index"] != s0["index"] and attempt < _retries - 1:
                continue
            raise CheckFailed(
                f"time rate {rate:.2f}x over {window}s window "
                f"({s0['time']:.1f}s → {s1['time']:.1f}s), expected ~1x"
            )

    def assert_time_frozen(self, window=3.0, tolerance=0.5):
        t0 = self.status()["time"]
        time.sleep(window)
        t1 = self.status()["time"]
        if abs(t1 - t0) > tolerance:
            raise CheckFailed(f"time moved {t0:.1f}s → {t1:.1f}s while paused")

    def assert_index(self, expected, timeout=5.0):
        deadline = time.time() + timeout
        idx = None
        while time.time() < deadline:
            idx = self.status()["index"]
            if idx == expected:
                return
            time.sleep(POLL_INTERVAL)
        raise CheckFailed(f"playlist index is {idx}, expected {expected}")

    def assert_position(self, target, tolerance=2.0, timeout=8.0):
        """Poll until the playhead is at target. NOTE: a playing track sweeps
        through every position, so this alone cannot prove a SEEK happened —
        only that the playhead ended up there. Seek proof lives in s4_seek
        (forward jump bigger than the poll window can sweep)."""
        deadline = time.time() + timeout
        t = None
        while time.time() < deadline:
            t = self.status()["time"]
            if abs(t - target) <= tolerance:
                return
            time.sleep(POLL_INTERVAL)
        raise CheckFailed(f"position {t:.1f}s, expected {target:.1f}±{tolerance}s")

    def wait_until_advancing(self, timeout=12.0):
        """Block until playback time is actually moving — loads, jumps and
        seeks re-buffer the stream for a few seconds, which would otherwise
        pollute the first rate-measurement window."""
        deadline = time.time() + timeout
        prev = self.status()["time"]
        while time.time() < deadline:
            time.sleep(1.0)
            cur = self.status()["time"]
            if cur - prev >= 0.8:
                return
            prev = cur
        raise CheckFailed(f"playback did not start advancing within {timeout}s")


# -- test playlist ----------------------------------------------------------


def pick_album(oracle):
    """Choose a library album with >= 2 tracks whose OPENING track (true track
    order, sort:tracknum) is short enough for a fast S5 boundary test, and
    which contains at least one track >= 45s for S4's provable seek.
    No hardcoded IDs — works against any populated server."""
    titles = oracle.rpc(["titles", 0, 500, "tags:de"]).get("titles_loop", [])
    albums = {}
    for t in titles:
        album_id = t.get("album_id")
        if album_id is not None:
            albums.setdefault(album_id, []).append(float(t.get("duration", 0) or 0))
    candidates = sorted(
        (a for a, d in albums.items() if len(d) >= 2 and max(d) >= 45),
        key=lambda a: sum(sorted(albums[a])[:2]),
    )
    for album_id in candidates[:10]:
        ordered = oracle.rpc(
            ["titles", 0, 2, "tags:d", "sort:tracknum", f"album_id:{album_id}"]
        ).get("titles_loop", [])
        if len(ordered) >= 2 and 20 <= float(ordered[0].get("duration", 0) or 0) <= 300:
            return album_id
    raise CheckFailed(
        "no suitable album in the first 500 library titles "
        "(need >= 2 tracks, opening track 20-300s, one track >= 45s)"
    )


def load_album(oracle, album_id):
    """Load the album (auto-plays) and wait for playback to register."""
    oracle.player_rpc(["playlistcontrol", "cmd:load", f"album_id:{album_id}"])
    deadline = time.time() + 10
    while time.time() < deadline:
        s = oracle.status()
        if s["mode"] == "play" and s["tracks"] >= 2:
            return s
        time.sleep(POLL_INTERVAL)
    raise CheckFailed(f"album {album_id} did not start playing within 10s: {oracle.status()}")


def ensure_playing(oracle, album_id):
    s = oracle.status()
    if s["tracks"] < 2:
        return load_album(oracle, album_id)
    if s["mode"] != "play":
        oracle.player_rpc(["play"])
        time.sleep(1)
    return oracle.status()


# -- scenarios ---------------------------------------------------------------


def s1_register_and_play(oracle, album_id):
    """Cold registration + first playback."""
    load_album(oracle, album_id)
    oracle.assert_mode("play")
    oracle.wait_until_advancing()  # initial buffering is not a stall
    oracle.assert_time_advancing(window=5.0)


def s2_pause_resume(oracle, album_id):
    ensure_playing(oracle, album_id)
    oracle.wait_until_advancing()
    # Get the playhead clear of 0 so a restart-from-start bug on resume is
    # distinguishable from a correct resume.
    deadline = time.time() + 30
    while oracle.status()["time"] < 5.0 and time.time() < deadline:
        time.sleep(1.0)
    oracle.player_rpc(["pause", "1"])
    time.sleep(0.5)
    oracle.assert_mode("pause")
    oracle.assert_time_frozen(window=3.0)
    pause_at = oracle.status()["time"]
    oracle.player_rpc(["pause", "0"])
    # Single post-settle sample, NOT a sweep-poll: a track restarted at 0
    # would land near 2.5s here, outside the window for any pause_at >= 5.
    time.sleep(2.5)
    t = oracle.status()["time"]
    if not (pause_at - 0.5 <= t <= pause_at + 4.0):
        raise CheckFailed(f"resume landed at {t:.1f}s, expected ~{pause_at:.1f}s")
    oracle.assert_time_advancing(window=4.0)


def s3_skip(oracle, album_id):
    ensure_playing(oracle, album_id)
    oracle.player_rpc(["playlist", "index", 0])
    oracle.assert_index(0)
    oracle.player_rpc(["playlist", "index", "+1"])
    oracle.assert_index(1)
    oracle.assert_position(0, tolerance=3.0)  # new track starts near 0
    oracle.player_rpc(["playlist", "index", "-1"])
    oracle.assert_index(0)
    oracle.wait_until_advancing()
    oracle.assert_time_advancing(window=4.0)


def s4_seek(oracle, album_id):
    """Seek must move the playhead DISCONTINUOUSLY. The forward jump (+25s) is
    bigger than natural playback can sweep within the 8s poll window, so a
    matched position proves the seek happened (review F-blocker fix)."""
    ensure_playing(oracle, album_id)
    durations = oracle.playlist_durations()
    longest = max(range(len(durations)), key=lambda i: durations[i])
    if durations[longest] < 45:
        raise CheckFailed(f"no track >= 45s in test playlist ({durations})")
    oracle.player_rpc(["playlist", "index", longest])
    oracle.assert_index(longest)
    oracle.wait_until_advancing()
    t0 = oracle.status()["time"]
    target = t0 + 25.0
    if target > durations[longest] - 10:
        raise CheckFailed(
            f"playhead {t0:.0f}s too deep in {durations[longest]:.0f}s track for +25s seek"
        )
    oracle.player_rpc(["time", target])
    oracle.assert_position(target, tolerance=2.5)
    oracle.wait_until_advancing()  # seek re-buffers like any stream restart
    oracle.assert_time_advancing(window=4.0)


def s5_gapless_boundary(oracle, album_id):
    """Track must flip to the NEXT index at the duration boundary — not tens of
    seconds early (the sfk bug class) and not stall. Effective window is
    -4s/+10s around the boundary: tighter risks false fails from LMS
    server-side time interpolation (see README)."""
    ensure_playing(oracle, album_id)
    oracle.player_rpc(["playlist", "index", 0])
    oracle.assert_index(0)
    oracle.wait_until_advancing()
    duration = oracle.status()["duration"]
    if duration < 20:
        raise CheckFailed(f"track 0 too short for boundary test ({duration}s)")
    lead_in = 15.0
    oracle.player_rpc(["time", duration - lead_in])
    oracle.assert_position(duration - lead_in, tolerance=2.5)
    started = time.time()
    deadline = started + lead_in + 10
    while time.time() < deadline:
        s = oracle.status()
        if s["index"] == 1:
            elapsed = time.time() - started
            if elapsed < lead_in - 4.0:
                raise CheckFailed(
                    f"boundary fired {lead_in - elapsed:.1f}s EARLY "
                    f"(after {elapsed:.1f}s, expected ~{lead_in:.0f}s) — sfk class"
                )
            oracle.wait_until_advancing()  # next track actually playing
            return
        if s["index"] not in (0, 1):
            raise CheckFailed(f"index jumped to {s['index']}, expected 0→1")
        time.sleep(POLL_INTERVAL)
    raise CheckFailed(f"no track boundary within {lead_in + 10:.0f}s — stalled at {oracle.status()}")


def s6_soak(oracle, album_id):
    """mode stays play and time keeps advancing, unattended."""
    ensure_playing(oracle, album_id)
    oracle.player_rpc(["playlist", "index", 0])
    oracle.wait_until_advancing()  # jump re-buffers; don't count that as a stall
    remaining = SOAK_SECONDS
    while remaining > 0:
        chunk = min(10.0, remaining)
        oracle.assert_time_advancing(window=chunk)
        remaining -= chunk


SCENARIOS = [
    ("S1", "register & play", s1_register_and_play),
    ("S2", "pause/resume", s2_pause_resume),
    ("S3", "skip next/prev", s3_skip),
    ("S4", "seek", s4_seek),
    ("S5", "gapless boundary", s5_gapless_boundary),
    ("S6", f"stall soak ({SOAK_SECONDS}s)", s6_soak),
]


def main():
    known = {sid for sid, _, _ in SCENARIOS}
    selected = set(a.upper() for a in sys.argv[1:]) or known
    unknown = selected - known
    if unknown:
        print(f"unknown scenario(s): {', '.join(sorted(unknown))} — "
              f"choose from {', '.join(sorted(known))}")
        return 2

    oracle = Oracle(LMS_HOST, LMS_PORT)
    try:
        if not oracle.player_id:
            print(f"discovering player {PLAYER_NAME!r} on {LMS_HOST}:{LMS_PORT} ...")
            oracle.discover(PLAYER_NAME)
        print(f"player: {oracle.player_id}")
        album_id = pick_album(oracle)
        print(f"test album: {album_id}\n")
    except (CheckFailed, OSError) as e:
        print(f"SETUP FAILED — {e}")
        return 1

    results = []
    for sid, label, fn in SCENARIOS:
        if sid not in selected:
            continue
        try:
            fn(oracle, album_id)
            results.append((sid, label, "PASS", ""))
        except CheckFailed as e:
            results.append((sid, label, "FAIL", str(e)))
        except Exception as e:  # network errors etc. — fail the scenario, keep going
            results.append((sid, label, "FAIL", f"{type(e).__name__}: {e}"))
        print(f"{sid} {label:<24} {results[-1][2]}"
              + (f"  — {results[-1][3]}" if results[-1][3] else ""))

    try:
        oracle.player_rpc(["stop"])
    except Exception:
        pass  # teardown must never eat the report

    failed = [r for r in results if r[2] == "FAIL"]
    print(f"\n{len(results) - len(failed)}/{len(results)} scenarios passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
