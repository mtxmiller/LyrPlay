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
| O10 | phase 2: paused, app quit, relaunched with the server unreachable (150s), "Play Saved Music" | LMS lands where the saved music got to (±8s), playing |
"""
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
    time.sleep(15)
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


def o6_lifeboat_midtrack(oracle, album_id):
    lifeboat_continuous(oracle, album_id, 90, kbps=400)


def o7_lifeboat_tracks(oracle, album_id):
    lifeboat_continuous(oracle, album_id, 420)


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
