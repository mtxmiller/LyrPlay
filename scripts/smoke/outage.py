#!/usr/bin/env python3
"""Outage scenarios: LyrPlay rides out a network drop (ride-out phase 1).

The app talks to LMS through faultproxy.py (scripts/smoke/faultproxy.py, on
the host next to the LMS); this script cuts the proxy's traffic and checks
LMS directly — the oracle never goes through the proxy, so it keeps working
while the player's "network" is down.

    LYRPLAY_APP_WEB_PORT=9011 LYRPLAY_APP_SLIM_PORT=3491 scripts/smoke/run.sh S1
    python3 scripts/smoke/outage.py            # all scenarios
    python3 scripts/smoke/outage.py O1 O3      # a subset

Env: the smoke.py knobs (LYRPLAY_LMS_HOST/PORT, LYRPLAY_PLAYER_NAME/ID), plus
    LYRPLAY_FAULT_CTL   fault proxy control URL (http://<LMS host>:9099)
    LYRPLAY_LIFEBOAT=1  the app runs with -Lifeboat 2 (O4 then expects continuous playback)

| ID | Outage | Pass criteria |
|----|--------|---------------|
| O1 | 25s, playing, connections survive (after=resume) | same track; LMS time = start + wall clock (±3s) once back: the audio never stopped and LMS never restarted it |
| O2 | 25s, playing, connections reset at the end (after=drop: Wi-Fi → cellular) | same track; time = start + wall clock (±4s) after recovery, never backwards |
| O3 | 40s, paused, connections reset | still paused at the paused time (±1s); Play resumes there |
| O4 | 90s, playing, download killed at the start (the buffer runs dry) | same track; resumes where the audio stopped: past LMS's frozen time, behind the wall clock |
| O5 | 320s, as O4 (LMS forgets the player after 300s) — slow, run only when named | as O4 |
| O6 | phase 2 (`-Lifeboat 2`): 90s, download killed, stream capped at 400 kbit/s beforehand (like a mobile link) | LMS lands where continuous playback would be (±6s): the downloaded copy took over mid-track |
| O7 | phase 2: 420s, download killed (crosses track boundaries and LMS's forget time) | as O6, on the right later track |
| O8 | phase 2: 240s offline, lock-screen Next, Pause, Play (Debug-build button hook) | LMS on the next track at the time played there (±6s) |
| O9 | phase 2: 90s offline, Pause after 20s | LMS paused afterwards, time not moving |
| O11 | no outage: paused, app frozen 40s (like iOS suspending it), lock-screen Play as it wakes | LMS playing again (the button reached LMS, not just the phone's old buffer) |
| O12 | phase 2: 120s offline, Next; then the web side is back while SlimProto still refuses (20s) | LMS on the next track at the time played there (±6s): a save during the refusals must not put back LMS's old track |
| O10 | phase 2: paused, app quit, relaunched with the server unreachable (150s), "Play Saved Music" | LMS lands where the saved music got to (±8s), playing |
| O13 | phase 2: last track of the playlist, 150s offline, its copy ends (repeat off) | LMS never behind what was heard, on the last track or stopped; 25s later not wrapped to track 0 |
| O14 | phase 2: as O13 with repeat all | LMS playing: the wrap (track 0) or the end of the last track, never replaying what was heard |
| O15 | phase 2: shuffle on, 240s offline across a boundary | LMS on the track (by id) and time continuous playback in SHUFFLED order would give (±6s) |
| O16 | phase 2: seek +60s, download killed 1s later, 90s offline | LMS at the seeked position + wall clock (±8s): the copy took over at the right place |
| O17 | phase 2: as O16, killed 6s after the seek (the 3s time poll has caught up) | as O16 |
| O18 | phase 2: 120s offline, back for 2s, 25s offline again (during the reconnect jump) | as O6 (±8s) |
| O19 | phase 2: 240s offline; meanwhile another controller inserts an album after the current track | LMS on the song played offline (found by id), at the time played there (±8s) |
| O20 | phase 2: offline Pause, 330s outage (LMS forgets the player) | LMS paused afterwards, time not moving |
| O21 | phase 2: as O13 with a 330s outage (LMS forgets the player) | as O13 |
| O22 | phase 2: the next track's copy deleted (failed download), outage across that boundary | offline playback stops there; LMS back at the end of that track or the start of the next, never replaying what was heard |
| O23 | phase 2: 150s offline; LyrPlay backgrounded (Settings app in front) 30s and foregrounded meanwhile | as O6 (±8s); screenshot of the offline player saved |
| O24 | phase 2: an (unreachable) backup server configured, 150s offline with copies; relaunches the app with the pref and reverts it | as O6 (±8s); screenshots every 20s show whether the offline UI flickers as the reconnect alternates servers |
| O25 | phase 2: a mixed FLAC/MP3 queue (`LYRPLAY_MIXED_TRACKS`), 240s offline across a FLAC → MP3 boundary (Opus copy, then the MP3 original at another rate) | as O6 (±8s) |
"""
import glob
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke  # noqa: E402
from smoke import CheckFailed  # noqa: E402

FAULT_CTL = os.environ.get("LYRPLAY_FAULT_CTL", f"http://{smoke.LMS_HOST}:9099")


def fault(path):
    r = subprocess.run(["curl", "-s", "-m", "5", f"{FAULT_CTL}{path}"], capture_output=True, text=True)
    if r.returncode != 0:
        raise CheckFailed(f"fault proxy at {FAULT_CTL} not reachable (curl exit {r.returncode})")
    return r.stdout


def connected(oracle):
    for p in oracle.rpc(["serverstatus", 0, 99]).get("players_loop", []):
        if p.get("playerid") == oracle.player_id:
            return bool(p.get("connected"))
    return False


def fresh_start(oracle, album_id, settle=8):
    """Album loaded from track 1, playing at 1x, a few seconds in."""
    smoke.load_album(oracle, album_id)
    oracle.wait_until_advancing(timeout=15)
    time.sleep(settle)
    return oracle.status()


def outage(secs, after):
    print(f"   … outage {secs}s (after={after})", flush=True)
    fault(f"/outage?secs={secs}&after={after}")
    time.sleep(secs)


def wait_back(oracle, timeout=30):
    """Player connected again and LMS time moving."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if connected(oracle):
            try:
                oracle.wait_until_advancing(timeout=max(2.0, deadline - time.time()))
                return
            except CheckFailed:
                pass
        time.sleep(1)
    raise CheckFailed(f"player not back and playing {timeout}s after the outage: {oracle.status()}")


def watch_monotonic(oracle, seconds=8):
    """LMS time never goes back once playback is back (a second restart or a
    restart at LMS's frozen time shows up as a step back)."""
    prev = oracle.status()
    for _ in range(int(seconds)):
        time.sleep(1)
        cur = oracle.status()
        if cur["index"] == prev["index"] and cur["time"] < prev["time"] - 0.5:
            raise CheckFailed(f"time went back {prev['time']:.1f}s → {cur['time']:.1f}s after the outage")
        prev = cur
    return prev


def o1_resume(oracle, album_id):
    s0, w0 = fresh_start(oracle, album_id), time.time()
    outage(25, "resume")
    wait_back(oracle)
    s = watch_monotonic(oracle)
    expected = s0["time"] + (time.time() - w0)
    if s["index"] != s0["index"]:
        raise CheckFailed(f"track changed {s0['index']} → {s['index']}")
    if abs(s["time"] - expected) > 3:
        raise CheckFailed(f"time {s['time']:.1f}s, expected {expected:.1f}±3s (start {s0['time']:.1f}s): "
                          "LMS restarted or the audio stopped")


def o2_cut(oracle, album_id):
    s0, w0 = fresh_start(oracle, album_id), time.time()
    outage(25, "drop")
    wait_back(oracle)
    s = watch_monotonic(oracle)
    expected = s0["time"] + (time.time() - w0)
    if s["index"] != s0["index"]:
        raise CheckFailed(f"track changed {s0['index']} → {s['index']}")
    if abs(s["time"] - expected) > 4:
        raise CheckFailed(f"time {s['time']:.1f}s, expected {expected:.1f}±4s (start {s0['time']:.1f}s)")


def o3_paused(oracle, album_id):
    fresh_start(oracle, album_id)
    oracle.player_rpc(["pause", "1"])
    time.sleep(2)
    p0 = oracle.status()
    if p0["mode"] != "pause":
        raise CheckFailed(f"did not pause: {p0}")
    outage(40, "drop")
    deadline = time.time() + 30
    while time.time() < deadline and not connected(oracle):
        time.sleep(1)
    time.sleep(4)  # let any reconnect handling run
    s = oracle.status()
    if s["mode"] != "pause" or abs(s["time"] - p0["time"]) > 1:
        raise CheckFailed(f"after the outage: mode {s['mode']}, time {s['time']:.1f}s; "
                          f"expected pause at {p0['time']:.1f}s")
    oracle.player_rpc(["pause", "0"])
    oracle.wait_until_advancing(timeout=15)
    s = oracle.status()
    if s["index"] != p0["index"] or not (p0["time"] - 1 <= s["time"] <= p0["time"] + 8):
        raise CheckFailed(f"Play resumed at {s['time']:.1f}s (track {s['index']}), "
                          f"expected about {p0['time']:.1f}s on track {p0['index']}")


LIFEBOAT = os.environ.get("LYRPLAY_LIFEBOAT") == "1"   # app launched with -Lifeboat 2


def o4_dry(oracle, album_id):
    if LIFEBOAT:
        # With downloaded copies the buffer never runs dry: playback is continuous.
        return lifeboat_continuous(oracle, album_id, 90)
    # Kill the download first: only LyrPlay's own buffer (~35s) is left, so the
    # audio stops well inside the outage. (Socket buffers alone can hold
    # minutes of compressed audio: 190s in the simulator rig.)
    s0, w0 = fresh_start(oracle, album_id), time.time()
    fault("/kill?scope=http")
    outage(90, "drop")
    wait_back(oracle, timeout=40)
    s = watch_monotonic(oracle)
    wall = s0["time"] + (time.time() - w0)
    if s["index"] != s0["index"]:
        raise CheckFailed(f"track changed {s0['index']} → {s['index']}")
    if s["time"] <= s0["time"] + 15:
        raise CheckFailed(f"time {s['time']:.1f}s: restarted near LMS's frozen {s0['time']:.1f}s, "
                          "not where the audio stopped")
    if s["time"] > wall - 20:
        raise CheckFailed(f"time {s['time']:.1f}s, wall clock {wall:.1f}s: skipped ahead past audio "
                          "that never played")
    print(f"   … resumed at {s['time']:.1f}s (start {s0['time']:.1f}s, wall clock {wall:.1f}s)")


def o5_forgotten(oracle, album_id):
    # Past LMS's 300s forget time: LMS ignores the reconnect bit and restarts
    # at its saved position; we must still land where the audio stopped.
    s0, w0 = fresh_start(oracle, album_id), time.time()
    fault("/kill?scope=http")
    outage(320, "drop")
    wait_back(oracle, timeout=40)
    s = watch_monotonic(oracle)
    wall = s0["time"] + (time.time() - w0)
    if s["index"] != s0["index"]:
        raise CheckFailed(f"track changed {s0['index']} → {s['index']}")
    if s["time"] <= s0["time"] + 15 or s["time"] > wall - 20:
        raise CheckFailed(f"time {s['time']:.1f}s (start {s0['time']:.1f}s, wall {wall:.1f}s): "
                          "not where the audio stopped")
    print(f"   … resumed at {s['time']:.1f}s (start {s0['time']:.1f}s, wall clock {wall:.1f}s)")


def expected_position(durations, index, time_in, elapsed):
    """Track and time after `elapsed` seconds of continuous playback."""
    t = time_in + elapsed
    while index < len(durations) and t >= durations[index]:
        t -= durations[index]
        index += 1
    return index, t


def lifeboat_continuous(oracle, album_id, secs, kbps=0):
    # Needs the app launched with -Lifeboat 2 and time to download the queue.
    # kbps caps the stream like a mobile link, so socket buffers don't hold
    # the whole track (on the LAN they do, and nothing is left to cut).
    fault(f"/shape?kbps={kbps}")
    try:
        s0 = fresh_start(oracle, album_id, settle=25)
    finally:
        fault("/shape?kbps=0")
    w0 = time.time()
    durations = oracle.playlist_durations()
    fault("/kill?scope=http")
    outage(secs, "drop")
    wait_back(oracle, timeout=45)
    time.sleep(6)  # a forgotten player's restart, then our correction jump
    s = watch_monotonic(oracle)
    idx, t = expected_position(durations, s0["index"], s0["time"], time.time() - w0)
    print(f"   … LMS at track {s['index']} {s['time']:.1f}s; continuous playback would be track {idx} {t:.1f}s")
    if s["index"] != idx or abs(s["time"] - t) > 6:
        raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {idx} {t:.1f}±6s "
                          "(playback did not continue through the outage)")


def o25_mixed_formats(oracle, album_id):
    # A queue mixing FLAC and MP3 files (LYRPLAY_MIXED_TRACKS, track ids in
    # play order, FLAC first): FLAC files get the stream's transcode as
    # copies, MP3 files their originals, so the outage crosses a copy with
    # another format and rate. LMS must land where continuous playback would.
    ids = os.environ.get("LYRPLAY_MIXED_TRACKS", "")
    if not ids:
        raise CheckFailed("set LYRPLAY_MIXED_TRACKS (e.g. 11,130,12,131: FLAC, MP3, ...)")
    oracle.player_rpc(["playlistcontrol", "cmd:load", f"track_id:{ids}"])
    oracle.wait_until_advancing(timeout=15)
    time.sleep(25)  # the copies download
    s0 = oracle.status()
    w0 = time.time()
    durations = oracle.playlist_durations()
    fault("/kill?scope=http")
    outage(240, "drop")
    wait_back(oracle, timeout=45)
    time.sleep(6)
    s = watch_monotonic(oracle)
    idx, t = expected_position(durations, s0["index"], s0["time"], time.time() - w0)
    print(f"   … LMS at track {s['index']} {s['time']:.1f}s; continuous playback would be track {idx} {t:.1f}s")
    if s["index"] != idx or abs(s["time"] - t) > 8:
        raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {idx} {t:.1f}±8s")


SIM_NAME = os.environ.get("LYRPLAY_SIM_NAME", "iPhone 17")


def press(button):
    """Press a lock-screen button in the simulator app (Debug builds: Darwin
    notification com.lmsstream.debug.remote.<button>)."""
    subprocess.run(["xcrun", "simctl", "spawn", SIM_NAME, "notifyutil", "-p",
                    f"com.lmsstream.debug.remote.{button}"], check=True)
    print(f"   … pressed {button}", flush=True)


def o8_offline_buttons(oracle, album_id):
    # Offline: Next, Pause, Play, then back online. LMS must land on the next
    # track at the time actually played there.
    s0 = fresh_start(oracle, album_id, settle=25)
    fault("/kill?scope=http")
    fault("/outage?secs=240&after=drop")
    print("   … outage 240s (after=drop)", flush=True)
    t0 = time.time()
    time.sleep(40); press("next"); t_next = time.time()
    time.sleep(20); press("pause"); t_pause = time.time()
    time.sleep(90); press("play"); t_play = time.time()
    time.sleep(max(0, 240 - (time.time() - t0)))
    wait_back(oracle, timeout=45)
    time.sleep(4)
    s = watch_monotonic(oracle)
    played = (t_pause - t_next) + (time.time() - t_play)
    print(f"   … LMS at track {s['index']} {s['time']:.1f}s; expected track {s0['index'] + 1} ~{played:.1f}s")
    if s["index"] != s0["index"] + 1 or abs(s["time"] - played) > 6:
        raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {s0['index'] + 1} {played:.1f}±6s")


def o9_paused_offline(oracle, album_id):
    # Offline: Pause. Back online (< 300s): LMS paused at the time we paused.
    fresh_start(oracle, album_id, settle=25)
    fault("/kill?scope=http")
    fault("/outage?secs=90&after=drop")
    print("   … outage 90s (after=drop)", flush=True)
    t0 = time.time()
    time.sleep(20); press("pause")
    s_at_pause_wall = time.time()
    time.sleep(max(0, 90 - (time.time() - t0)))
    deadline = time.time() + 40
    while time.time() < deadline and not connected(oracle):
        time.sleep(1)
    time.sleep(8)
    s = oracle.status()
    print(f"   … LMS {s['mode']} at track {s['index']} {s['time']:.1f}s")
    if s["mode"] != "pause":
        raise CheckFailed(f"LMS mode {s['mode']} after a pause made offline, expected pause")
    t = s["time"]
    time.sleep(3)
    if abs(oracle.status()["time"] - t) > 0.5:
        raise CheckFailed("time moving while LMS says paused")


def relaunch_app():
    # Settings were seeded into the app's preferences by run.sh: a plain launch keeps them.
    subprocess.run(["xcrun", "simctl", "terminate", SIM_NAME, "elm.LMS-StreamTest"], capture_output=True)
    subprocess.run(["xcrun", "simctl", "launch", SIM_NAME, "elm.LMS-StreamTest"], check=True, capture_output=True)
    print("   … app relaunched", flush=True)


def o10_saved_music_launch(oracle, album_id):
    # Quit while playing, relaunch in a "dead spot", play the saved copies,
    # then the network comes back: LMS must move to where the saved music got to.
    # Paused, then quit (the usual way to end up here): the saved position is exact.
    fresh_start(oracle, album_id, settle=25)
    durations = oracle.playlist_durations()
    oracle.player_rpc(["pause", "1"])
    time.sleep(3)
    s_quit = oracle.status()
    fault("/outage?secs=150&after=drop&new=refuse")
    print(f"   … paused at {s_quit['time']:.1f}s; outage 150s (new connections refused)", flush=True)
    t0 = time.time()
    relaunch_app()
    # After the app's 8 reconnect attempts gave up (~17s): pressing Play must
    # start them again, or LMS is never moved (2026-10-19).
    time.sleep(25)
    press("playsaved"); t_play = time.time()
    time.sleep(max(0, 150 - (time.time() - t0)))
    wait_back(oracle, timeout=45)
    time.sleep(6)
    s = watch_monotonic(oracle)
    idx, t = expected_position(durations, s_quit["index"], s_quit["time"], time.time() - t_play)
    print(f"   … LMS at track {s['index']} {s['time']:.1f}s; saved music would be at track {idx} {t:.1f}s")
    if s["index"] != idx or abs(s["time"] - t) > 8:
        raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {idx} {t:.1f}±8s")


def app_signal(sig):
    r = subprocess.run(["pgrep", "-f", "LMS_StreamTest.app/LMS_StreamTest"], capture_output=True, text=True)
    pids = r.stdout.split()
    if not pids:
        raise CheckFailed("app process not found")
    subprocess.run(["kill", f"-{sig}"] + pids, check=True)


def o11_suspended_play(oracle, album_id):
    # The network is fine; the app's connection died because iOS suspended it.
    # A lock-screen Play then must go to LMS (device log 2026-10-19).
    fresh_start(oracle, album_id, settle=10)
    oracle.player_rpc(["pause", "1"])
    time.sleep(3)
    app_signal("STOP")
    print("   … app frozen 40s", flush=True)
    try:
        time.sleep(40)
    finally:
        app_signal("CONT")
    press("play")
    wait_back(oracle, timeout=30)
    s = oracle.status()
    print(f"   … LMS {s['mode']} at track {s['index']} {s['time']:.1f}s")
    if s["mode"] != "play":
        raise CheckFailed(f"LMS {s['mode']} after lock-screen Play, expected play")


def o12_skip_then_slow_reconnect(oracle, album_id):
    # Device log 2026-10-19: offline skip A → B; when the network came back the
    # first SlimProto connect timed out, and the save on that disconnect asked
    # LMS (reachable again) for its track: A. The reconnect jumped to A.
    s0 = fresh_start(oracle, album_id, settle=25)
    fault("/kill?scope=http")
    fault("/outage?secs=120&after=drop")
    print("   … outage 120s (after=drop)", flush=True)
    t0 = time.time()
    time.sleep(40); press("next"); t_next = time.time()
    time.sleep(max(0, 120 - (time.time() - t0)))
    fault("/end")
    fault("/outage?secs=20&after=drop&scope=slim&new=refuse")
    print("   … web back, SlimProto refused 20s", flush=True)
    time.sleep(20)
    wait_back(oracle, timeout=45)
    time.sleep(4)
    s = watch_monotonic(oracle)
    played = time.time() - t_next
    print(f"   … LMS at track {s['index']} {s['time']:.1f}s; expected track {s0['index'] + 1} ~{played:.1f}s")
    if s["index"] != s0["index"] + 1 or abs(s["time"] - played) > 6:
        raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {s0['index'] + 1} {played:.1f}±6s")


def o6_lifeboat_midtrack(oracle, album_id):
    lifeboat_continuous(oracle, album_id, 90, kbps=400)


def o7_lifeboat_tracks(oracle, album_id):
    lifeboat_continuous(oracle, album_id, 420)


# -- edge cases (review 2026-10-19) -------------------------------------------

def current_track_id(oracle):
    loop = oracle.player_rpc(["status", "-", 1, "tags:"]).get("playlist_loop", [])
    return str(loop[0]["id"]) if loop else None


def play_order_ids(oracle):
    return [str(t["id"]) for t in oracle.player_rpc(["status", 0, 99, "tags:"]).get("playlist_loop", [])]


def start_last_track(oracle, album_id, seconds_left, settle=12):
    """Album loaded, playing the LAST track with `seconds_left` to go (the
    copies' plan then holds only that track)."""
    smoke.load_album(oracle, album_id)
    oracle.wait_until_advancing(timeout=15)
    durations = oracle.playlist_durations()
    last = len(durations) - 1
    oracle.player_rpc(["playlist", "index", last])
    time.sleep(2)
    oracle.player_rpc(["time", str(max(1, durations[last] - seconds_left))])
    oracle.wait_until_advancing(timeout=15)
    time.sleep(settle)   # the plan (3s after the strm) and its download
    s0 = oracle.status()
    if s0["index"] != last:
        raise CheckFailed(f"not on the last track: {s0}")
    return s0, durations


def o13_end_of_playlist_offline(oracle, album_id):
    # The last copy ends during the outage (nothing follows). Afterwards LMS
    # must not be behind where the user stopped hearing it, and never on
    # another track than the last one (repeat off): end of the playlist.
    oracle.player_rpc(["playlist", "repeat", 0])
    s0, durations = start_last_track(oracle, album_id, 45)
    last = len(durations) - 1
    fault("/kill?scope=http")
    outage(150, "drop")
    deadline = time.time() + 45
    while time.time() < deadline and not connected(oracle):
        time.sleep(1)
    time.sleep(12)
    s = oracle.status()
    print(f"   … LMS {s['mode']} at track {s['index']} {s['time']:.1f}s (last track {last}, {durations[last]:.0f}s)")
    if s["mode"] == "play":
        if s["index"] != last:
            raise CheckFailed(f"playing track {s['index']} after the playlist ended offline (expected {last} or stop)")
        if s["time"] < durations[last] - 50:
            raise CheckFailed(f"playing the last track from {s['time']:.1f}s: behind what was already heard")
    elif s["mode"] != "stop":
        raise CheckFailed(f"mode {s['mode']} after the playlist ended offline")
    settle_after_playlist_end(oracle, last)


def settle_after_playlist_end(oracle, last):
    """25s later LMS must have stopped (repeat off): a jump to the end of the
    last track is a "next track" to LMS, which wraps to track 0 and plays."""
    time.sleep(25)
    s = oracle.status()
    print(f"   … 25s later: LMS {s['mode']} at track {s['index']} {s['time']:.1f}s")
    if s["mode"] == "play" and s["index"] != last:
        raise CheckFailed(f"LMS wrapped to track {s['index']} and is playing: the playlist had ended (repeat off)")
    if s["mode"] == "play":
        t = s["time"]
        time.sleep(3)
        if oracle.status()["time"] > t + 1:
            raise CheckFailed(f"LMS replaying the last track from {t:.1f}s after the playlist ended offline")
        # A jump to the END of the last track gets an STMd but never an STMu
        # (nothing plays), so LMS sits in "play" at the end for good.
        raise CheckFailed(f"LMS stuck in play at {t:.1f}s (end of the last track) instead of stop")


def o14_repeat_all_offline(oracle, album_id):
    # Repeat all: LMS would wrap to track 0, but no copy of it is ahead in
    # the plan. Once back, LMS must be playing from the start of the wrap
    # (track 0), not replaying the heard end of the last track.
    oracle.player_rpc(["playlist", "repeat", 2])
    try:
        s0, durations = start_last_track(oracle, album_id, 45)
        last = len(durations) - 1
        fault("/kill?scope=http")
        outage(150, "drop")
        wait_back(oracle, timeout=45)
        time.sleep(8)
        s = watch_monotonic(oracle, 6)
        print(f"   … LMS {s['mode']} at track {s['index']} {s['time']:.1f}s (last track {last})")
        if s["mode"] != "play":
            raise CheckFailed(f"mode {s['mode']}, expected play (repeat all)")
        if s["index"] == last and s["time"] < durations[last] - 50:
            raise CheckFailed(f"replaying the last track from {s['time']:.1f}s: already heard")
        if s["index"] not in (0, last):
            raise CheckFailed(f"on track {s['index']}, expected the wrap (0) or the end of {last}")
    finally:
        oracle.player_rpc(["playlist", "repeat", 0])


def o15_shuffle_offline(oracle, album_id):
    # Shuffled queue: offline Next-track must follow LMS's play order (the
    # plan uses `playlist index`), and the reconnect must land on that track.
    oracle.player_rpc(["playlist", "shuffle", 1])
    try:
        s0 = fresh_start(oracle, album_id, settle=25)
        ids = play_order_ids(oracle)
        durations = oracle.playlist_durations()
        w0 = time.time()
        fault("/kill?scope=http")
        outage(240, "drop")
        wait_back(oracle, timeout=45)
        time.sleep(6)
        s = watch_monotonic(oracle)
        idx, t = expected_position(durations, s0["index"], s0["time"], time.time() - w0)
        got = current_track_id(oracle)
        print(f"   … LMS at track {s['index']} (id {got}) {s['time']:.1f}s; continuous: track {idx} (id {ids[idx]}) {t:.1f}s")
        if s["index"] != idx or got != ids[idx] or abs(s["time"] - t) > 6:
            raise CheckFailed(f"LMS at track {s['index']} id {got} {s['time']:.1f}s, expected track {idx} id {ids[idx]} {t:.1f}±6s")
    finally:
        oracle.player_rpc(["playlist", "shuffle", 0])


def seek_then_cut(oracle, album_id, gap):
    # A seek `gap` seconds before the download dies: the copy's switch point
    # is an estimate (the app learns the seek from a 3s server-time poll) plus
    # an audio match in an 8s window.
    # Unshaped while the copies download (the cap would slow them too: a copy
    # still downloading at the cut can't take over). The seek starts a new
    # stream, which is what the cap has to keep short.
    s0 = fresh_start(oracle, album_id, settle=25)
    durations = oracle.playlist_durations()
    target = s0["time"] + 60
    if target > durations[s0["index"]] - 60:
        raise CheckFailed(f"opening track too short for a +60s seek ({durations[s0['index']]:.0f}s)")
    fault("/shape?kbps=400")
    try:
        oracle.player_rpc(["time", f"{target:.1f}"])
        w0 = time.time()
        time.sleep(gap)
        fault("/kill?scope=http")
    finally:
        fault("/shape?kbps=0")
    outage(90, "drop")
    wait_back(oracle, timeout=45)
    time.sleep(6)
    s = watch_monotonic(oracle)
    idx, t = expected_position(durations, s0["index"], target, time.time() - w0)
    print(f"   … LMS at track {s['index']} {s['time']:.1f}s; continuous from the seek: track {idx} {t:.1f}s")
    if s["index"] != idx or abs(s["time"] - t) > 8:
        raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {idx} {t:.1f}±8s "
                          "(the copy did not take over at the seeked position)")


def o16_seek_1s_before_cut(oracle, album_id):
    seek_then_cut(oracle, album_id, 1.0)


def o17_seek_6s_before_cut(oracle, album_id):
    seek_then_cut(oracle, album_id, 6.0)


def o18_flap_during_jump(oracle, album_id):
    # The network comes back, and drops again ~2s later, while the reconnect
    # is moving LMS to us. The second return must still land at our place.
    s0 = fresh_start(oracle, album_id, settle=25)
    w0 = time.time()
    durations = oracle.playlist_durations()
    fault("/kill?scope=http")
    outage(120, "drop")
    time.sleep(2.0)
    outage(25, "drop")
    wait_back(oracle, timeout=45)
    time.sleep(6)
    s = watch_monotonic(oracle)
    idx, t = expected_position(durations, s0["index"], s0["time"], time.time() - w0)
    print(f"   … LMS at track {s['index']} {s['time']:.1f}s; continuous playback would be track {idx} {t:.1f}s")
    if s["index"] != idx or abs(s["time"] - t) > 8:
        raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {idx} {t:.1f}±8s")


def o19_queue_edited_offline(oracle, album_id):
    # Another controller inserts songs after the current track during the
    # outage. Offline we play the OLD next track from its copy; back online
    # LMS must be on that same song (found by id) at the time played there.
    s0 = fresh_start(oracle, album_id, settle=25)
    ids = play_order_ids(oracle)
    durations = oracle.playlist_durations()
    w0 = time.time()
    other = next(a for a in [a["id"] for a in oracle.rpc(["albums", 0, 50]).get("albums_loop", [])] if a != album_id)
    fault("/kill?scope=http")
    fault("/outage?secs=240&after=drop")
    print("   … outage 240s (after=drop)", flush=True)
    time.sleep(10)
    oracle.player_rpc(["playlistcontrol", "cmd:insert", f"album_id:{other}"])
    new_ids = play_order_ids(oracle)
    print(f"   … inserted album {other} after the current track ({len(ids)} → {len(new_ids)} tracks)")
    time.sleep(230)
    wait_back(oracle, timeout=45)
    time.sleep(6)
    s = watch_monotonic(oracle)
    idx, t = expected_position(durations, s0["index"], s0["time"], time.time() - w0)
    want = ids[idx]
    got = current_track_id(oracle)
    print(f"   … LMS on id {got} at track {s['index']} {s['time']:.1f}s; played offline: id {want} "
          f"(now at index {new_ids.index(want) if want in new_ids else '?'}) {t:.1f}s")
    if got != want or abs(s["time"] - t) > 8:
        raise CheckFailed(f"LMS on id {got} {s['time']:.1f}s, expected id {want} {t:.1f}±8s")


def o20_paused_offline_forgotten(oracle, album_id):
    # Offline Pause, then LMS forgets the player (> 300s). Back: LMS must be
    # paused at the paused time, not playing LMS's own restart.
    fresh_start(oracle, album_id, settle=25)
    fault("/kill?scope=http")
    fault("/outage?secs=330&after=drop")
    print("   … outage 330s (after=drop)", flush=True)
    t0 = time.time()
    time.sleep(20); press("pause")
    time.sleep(max(0, 330 - (time.time() - t0)))
    deadline = time.time() + 45
    while time.time() < deadline and not connected(oracle):
        time.sleep(1)
    time.sleep(12)
    s = oracle.status()
    print(f"   … LMS {s['mode']} at track {s['index']} {s['time']:.1f}s")
    if s["mode"] != "pause":
        raise CheckFailed(f"LMS mode {s['mode']} after a pause made offline and a 330s outage, expected pause")
    t = s["time"]
    time.sleep(3)
    if abs(oracle.status()["time"] - t) > 0.5:
        raise CheckFailed("time moving while LMS says paused")


def o21_copies_ran_out_forgotten(oracle, album_id):
    # The last copy ends offline and LMS forgets us (> 300s): as O13, but LMS
    # restarts a forgotten player at its own saved position.
    oracle.player_rpc(["playlist", "repeat", 0])
    s0, durations = start_last_track(oracle, album_id, 45)
    last = len(durations) - 1
    fault("/kill?scope=http")
    outage(330, "drop")
    deadline = time.time() + 45
    while time.time() < deadline and not connected(oracle):
        time.sleep(1)
    time.sleep(15)
    s = oracle.status()
    print(f"   … LMS {s['mode']} at track {s['index']} {s['time']:.1f}s (last track {last}, {durations[last]:.0f}s)")
    if s["mode"] == "play":
        if s["index"] != last:
            raise CheckFailed(f"playing track {s['index']} after the playlist ended offline (expected {last} or stop)")
        if s["time"] < durations[last] - 50:
            raise CheckFailed(f"playing the last track from {s['time']:.1f}s: behind what was already heard")
    elif s["mode"] != "stop":
        raise CheckFailed(f"mode {s['mode']} after the playlist ended offline")
    settle_after_playlist_end(oracle, last)


def o22_missing_copy_in_plan(oracle, album_id):
    # The next track's copy is missing (failed download): offline playback
    # must stop at that boundary, and LMS must not come back behind or on an
    # unrelated track.
    s0 = fresh_start(oracle, album_id, settle=25)
    ids = play_order_ids(oracle)
    durations = oracle.playlist_durations()
    nxt = s0["index"] + 1
    container = subprocess.run(["xcrun", "simctl", "get_app_container", SIM_NAME, "elm.LMS-StreamTest", "data"],
                               capture_output=True, text=True, check=True).stdout.strip()
    # <id>.audio for an original copy, <id>.<variant>.audio for a transcode
    copies = glob.glob(os.path.join(container, "Library", "Caches", "Lifeboat", f"{ids[nxt]}.*audio"))
    if not copies:
        raise CheckFailed(f"no copy of the next track (id {ids[nxt]}) to remove in {container}")
    victim = copies[0]
    os.remove(victim)
    print(f"   … removed the copy of track {nxt} (id {ids[nxt]})", flush=True)
    w0 = time.time()
    fault("/kill?scope=http")
    outage(durations[s0["index"]] - s0["time"] + 60, "drop")
    wait_back(oracle, timeout=45)
    time.sleep(8)
    s = watch_monotonic(oracle, 6)
    got = current_track_id(oracle)
    print(f"   … LMS {s['mode']} at track {s['index']} (id {got}) {s['time']:.1f}s; wall clock would be "
          f"track {expected_position(durations, s0['index'], s0['time'], time.time() - w0)}")
    if s["index"] not in (s0["index"], nxt):
        raise CheckFailed(f"LMS on track {s['index']}, expected the end of {s0['index']} or the start of {nxt}")
    if s["index"] == s0["index"] and s["time"] < durations[s0["index"]] - 20:
        raise CheckFailed(f"replaying track {s0['index']} from {s['time']:.1f}s: already heard")
    if s["index"] == nxt and s["time"] > 60:
        raise CheckFailed(f"track {nxt} at {s['time']:.1f}s: skipped ahead past audio that never played")


def o23_background_foreground_offline(oracle, album_id):
    # Playing copies offline, the app goes to the background (another app in
    # front) and comes back: the foreground recovery must not disturb the
    # offline playback, and the reconnect must still land where we are.
    s0 = fresh_start(oracle, album_id, settle=25)
    w0 = time.time()
    durations = oracle.playlist_durations()
    fault("/kill?scope=http")
    fault("/outage?secs=150&after=drop")
    print("   … outage 150s (after=drop)", flush=True)
    time.sleep(40)
    subprocess.run(["xcrun", "simctl", "launch", SIM_NAME, "com.apple.Preferences"], capture_output=True)
    print("   … Settings app in front (LyrPlay in the background)", flush=True)
    time.sleep(30)
    subprocess.run(["xcrun", "simctl", "launch", SIM_NAME, "elm.LMS-StreamTest"], capture_output=True)
    print("   … LyrPlay in front again", flush=True)
    time.sleep(5)
    shot = os.path.join(os.environ.get("LYRPLAY_SHOT_DIR", "/tmp"), "o23-offline-player.png")
    subprocess.run(["xcrun", "simctl", "io", SIM_NAME, "screenshot", shot], capture_output=True)
    print(f"   … screenshot {shot}", flush=True)
    time.sleep(max(0, 150 - (time.time() - w0)))
    wait_back(oracle, timeout=45)
    time.sleep(6)
    s = watch_monotonic(oracle)
    idx, t = expected_position(durations, s0["index"], s0["time"], time.time() - w0)
    print(f"   … LMS at track {s['index']} {s['time']:.1f}s; continuous playback would be track {idx} {t:.1f}s")
    if s["index"] != idx or abs(s["time"] - t) > 8:
        raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {idx} {t:.1f}±8s")


def seed_pref(key, kind, value):
    container = subprocess.run(["xcrun", "simctl", "get_app_container", SIM_NAME, "elm.LMS-StreamTest", "data"],
                               capture_output=True, text=True, check=True).stdout.strip()
    plist = os.path.join(container, "Library", "Preferences", "elm.LMS-StreamTest")
    subprocess.run(["xcrun", "simctl", "spawn", SIM_NAME, "defaults", "write", plist, key, kind, str(value)], check=True)


def app_log_count(pattern, minutes):
    r = subprocess.run(["xcrun", "simctl", "spawn", SIM_NAME, "log", "show", "--last", f"{minutes}m", "--info",
                        "--predicate", 'subsystem == "com.lmsstream"'], capture_output=True, text=True)
    return sum(1 for line in r.stdout.splitlines() if pattern in line)


def o24_backup_server_offline(oracle, album_id):
    # A backup server is configured (unreachable here, like a second LMS at
    # home when the car is in a dead spot). The reconnect attempts alternate
    # primary/backup every 2 failures; the copies belong to the primary.
    # Playback must still land where we are, and the offline UI (banner /
    # player) should not flicker with the active server: screenshots saved.
    seed_pref("BackupServerHost", "-string", "192.168.1.250")
    seed_pref("BackupServerWebPort", "-int", 9000)
    seed_pref("BackupServerSlimProtoPort", "-int", 3483)
    seed_pref("IsBackupServerEnabled", "-bool", "YES")
    try:
        relaunch_app()
        oracle.discover(smoke.PLAYER_NAME, timeout=40)
        s0 = fresh_start(oracle, album_id, settle=25)
        w0 = time.time()
        durations = oracle.playlist_durations()
        fault("/kill?scope=http")
        fault("/outage?secs=150&after=drop")
        print("   … outage 150s (after=drop)", flush=True)
        shots = os.environ.get("LYRPLAY_SHOT_DIR", "/tmp")
        for i, at in enumerate((25, 45, 65, 85, 105, 125)):
            time.sleep(max(0, at - (time.time() - w0)))
            path = os.path.join(shots, f"o24-offline-{i}.png")
            subprocess.run(["xcrun", "simctl", "io", SIM_NAME, "screenshot", path], capture_output=True)
        time.sleep(max(0, 150 - (time.time() - w0)))
        wait_back(oracle, timeout=60)
        time.sleep(6)
        s = watch_monotonic(oracle)
        idx, t = expected_position(durations, s0["index"], s0["time"], time.time() - w0)
        switches = app_log_count("switching to backup", 5)
        print(f"   … LMS at track {s['index']} {s['time']:.1f}s; continuous playback would be track {idx} {t:.1f}s; "
              f"{switches} switch(es) to the backup during the outage; screenshots in {shots}")
        if s["index"] != idx or abs(s["time"] - t) > 8:
            raise CheckFailed(f"LMS at track {s['index']} {s['time']:.1f}s, expected track {idx} {t:.1f}±8s")
    finally:
        seed_pref("IsBackupServerEnabled", "-bool", "NO")
        relaunch_app()


SCENARIOS = [
    ("O1", "25s, connections survive", o1_resume),
    ("O2", "25s, download cut", o2_cut),
    ("O3", "40s paused, cut", o3_paused),
    ("O4", "90s, download killed, dry", o4_dry),
    ("O5", "320s, LMS forgets us", o5_forgotten),   # slow: only when asked for
    # Phase 2 (app launched with -Lifeboat 2), only when named:
    ("O6", "90s killed, plays the copy", o6_lifeboat_midtrack),
    ("O7", "420s, copies across tracks", o7_lifeboat_tracks),
    ("O8", "offline Next/Pause/Play", o8_offline_buttons),
    ("O9", "paused offline, back < 5min", o9_paused_offline),
    ("O10", "offline launch, saved music", o10_saved_music_launch),
    ("O11", "suspended, lock-screen Play", o11_suspended_play),
    ("O12", "offline skip, slow reconnect", o12_skip_then_slow_reconnect),
    # Edge cases (review 2026-10-19), phase 2, only when named:
    ("O13", "end of playlist offline", o13_end_of_playlist_offline),
    ("O14", "repeat all, end offline", o14_repeat_all_offline),
    ("O15", "shuffle, boundary offline", o15_shuffle_offline),
    ("O16", "seek 1s before the cut", o16_seek_1s_before_cut),
    ("O17", "seek 6s before the cut", o17_seek_6s_before_cut),
    ("O18", "flap during the jump", o18_flap_during_jump),
    ("O19", "queue edited offline", o19_queue_edited_offline),
    ("O20", "paused offline, forgotten", o20_paused_offline_forgotten),
    ("O21", "copies ran out, forgotten", o21_copies_ran_out_forgotten),
    ("O22", "missing copy in the plan", o22_missing_copy_in_plan),
    ("O23", "background/foreground offline", o23_background_foreground_offline),
    ("O24", "backup server set, offline", o24_backup_server_offline),
    ("O25", "mixed FLAC/MP3 queue offline", o25_mixed_formats),
]
DEFAULT = {"O1", "O2", "O3", "O4"}


def main():
    known = {sid for sid, _, _ in SCENARIOS}
    selected = set(a.upper() for a in sys.argv[1:]) or DEFAULT
    if selected - known:
        print(f"unknown scenario(s): {', '.join(sorted(selected - known))}")
        return 2
    oracle = smoke.Oracle(smoke.LMS_HOST, smoke.LMS_PORT)
    try:
        fault("/status")
        if not oracle.player_id:
            oracle.discover(smoke.PLAYER_NAME)
        album_id = smoke.pick_album(oracle)
        print(f"player {oracle.player_id}, album {album_id}, fault proxy {FAULT_CTL}\n")
    except (CheckFailed, OSError) as e:
        print(f"SETUP FAILED — {e}")
        return 1
    failed = 0
    for sid, label, fn in SCENARIOS:
        if sid not in selected:
            continue
        try:
            fn(oracle, album_id)
            result = "PASS"
        except CheckFailed as e:
            result, failed = f"FAIL — {e}", failed + 1
        except Exception as e:
            import traceback
            traceback.print_exc()
            result, failed = f"FAIL — {type(e).__name__}: {e}", failed + 1
        finally:
            fault("/end")
        print(f"{sid} {label:<28} {result}", flush=True)
        time.sleep(3)
    try:
        oracle.player_rpc(["stop"])
    except Exception:
        pass
    n = len([s for s in SCENARIOS if s[0] in selected])
    print(f"\n{n - failed}/{n} outage scenarios passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
