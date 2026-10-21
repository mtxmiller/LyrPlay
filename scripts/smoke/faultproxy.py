#!/usr/bin/env python3
"""Network fault proxy for LyrPlay outage tests.

Sits between the player and an LMS and imitates a dead spot without touching
the player: point LyrPlay's server at the proxy's ports, and the oracle at the
LMS itself (so it keeps working while the "network" is down).

    player ── web/stream :9011 ──▶ proxy ──▶ LMS :9010
    player ── SlimProto  :3491 ──▶ proxy ──▶ LMS :3490
    you    ── control    :9099 ──▶ proxy

Control (plain HTTP GET, e.g. with curl):
    /outage?secs=40[&after=drop|resume][&scope=all|slim|http][&new=refuse|hold]
        Freeze traffic for `secs`. Open connections stop moving bytes in both
        directions (nothing is read, so TCP backpressure builds as in a dead
        spot). New connections are refused (default: the player sees a failed
        connect, as with no route) or held (accepted, nothing forwarded: the
        player thinks it is connected and has to notice the silence). At the end, `after=drop` (default) resets everything that was
        frozen or held, as when TCP gives up during a long dead spot;
        `after=resume` lets the same connections carry on, as after a short
        blip where TCP survives.
    /kill[?scope=...]   Reset matching connections now (Wi-Fi → cellular: the
                        old address is gone).
    /shape?kbps=N       Cap each web/stream connection's download to N kbit/s
                        (0 = no cap). On a LAN, LMS sends a whole track in a
                        second and it sits in socket buffers; a mobile link
                        keeps only a little ahead.
    /end                End the current outage now (applies its `after`).
    /status             JSON: outage state and open connections.
    /requests[?since=T] JSON: HTTP requests the player sent through the proxy
                        (every request line, also on kept-alive connections),
                        with the proxy's clock `t` (epoch) and its `now`, so
                        a harness can tell which songs were streamed.

Run on the host that reaches the LMS (ser5 for lms-test):
    python3 faultproxy.py [--lms-host 127.0.0.1] [--web 9011:9010] [--slim 3491:3490] [--ctl 9099]
Events are printed with timestamps (one line each), for lining up with the
app's log and the oracle.
"""
import argparse
import asyncio
import collections
import itertools
import json
import socket
import sys
import time
from urllib.parse import parse_qs, urlparse

T0 = time.time()


def log(*a):
    print(f"{time.strftime('%H:%M:%S')} [{time.time() - T0:8.2f}]", *a, flush=True)


class Outage:
    def __init__(self):
        self.active = False
        self.scope = "all"
        self.after = "drop"
        self.new = "refuse"
        self.ends_at = 0.0
        self.cleared = asyncio.Event()
        self.cleared.set()
        self.timer = None

    def covers(self, kind):
        return self.active and self.scope in ("all", kind)


class Conn:
    ids = itertools.count(1)

    def __init__(self, kind, cr, cw):
        self.id = next(Conn.ids)
        self.kind = kind
        self.cr, self.cw = cr, cw
        self.ur = self.uw = None
        self.peer = cw.get_extra_info("peername")
        self.opened = time.time()
        self.up_bytes = self.down_bytes = 0
        self.frozen = False      # caught by the current outage (dropped at its end if after=drop)
        self.first_line = ""

    def describe(self):
        return {"id": self.id, "kind": self.kind, "peer": f"{self.peer[0]}:{self.peer[1]}",
                "age_s": round(time.time() - self.opened, 1), "to_lms": self.up_bytes,
                "to_player": self.down_bytes, "frozen": self.frozen, "request": self.first_line}

    def reset(self):
        for w in (self.cw, self.uw):
            if w is None:
                continue
            try:
                s = w.get_extra_info("socket")
                if s is not None:   # RST instead of FIN, like a dead path
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\x01\x00\x00\x00\x00\x00\x00\x00")
                w.transport.abort()
            except Exception:
                pass


class Proxy:
    def __init__(self, lms_host, routes):
        self.lms_host = lms_host
        self.routes = routes     # kind -> (listen port, upstream port)
        self.outage = Outage()
        self.conns = {}
        self.kbps = 0
        self.requests = collections.deque(maxlen=5000)

    # -- data path ------------------------------------------------------------
    async def gate(self, conn):
        """Wait while an outage covers this connection."""
        while self.outage.covers(conn.kind):
            conn.frozen = True
            await self.outage.cleared.wait()

    async def pump(self, conn, reader, writer, up):
        try:
            while True:
                await self.gate(conn)
                data = await reader.read(16384 if (self.kbps and not up) else 65536)
                if not data:
                    break
                await self.gate(conn)   # an outage that began during the read holds the data
                if up:
                    conn.up_bytes += len(data)
                    if not conn.first_line and conn.kind == "http":
                        conn.first_line = data.split(b"\r\n", 1)[0].decode("latin1")[:120]
                    if conn.kind == "http" and data[:5] in (b"GET /", b"POST ", b"HEAD "):
                        line = data.split(b"\r\n", 1)[0].decode("latin1")[:200]
                        self.requests.append({"t": round(time.time(), 3), "conn": conn.id, "request": line})
                        if line.startswith("GET /stream"):
                            log(f"#{conn.id} {line}")
                else:
                    conn.down_bytes += len(data)
                writer.write(data)
                await writer.drain()
                if not up and conn.kind == "http" and self.kbps > 0:
                    await asyncio.sleep(len(data) * 8 / (self.kbps * 1000))
        except (ConnectionError, OSError, asyncio.IncompleteReadError):
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def handle(self, kind, cr, cw):
        conn = Conn(kind, cr, cw)
        self.conns[conn.id] = conn
        try:
            if self.outage.covers(kind):
                if self.outage.new == "refuse":
                    log(f"#{conn.id} {kind} from {conn.peer[0]} refused (outage)")
                    conn.reset()
                    return
                log(f"#{conn.id} {kind} from {conn.peer[0]} held (outage)")
                await self.gate(conn)
                if conn.frozen and self.outage_ended_with_drop:
                    log(f"#{conn.id} {kind} held connection reset at outage end")
                    conn.reset()
                    return
            try:
                conn.ur, conn.uw = await asyncio.open_connection(self.lms_host, self.routes[kind][1])
            except OSError as e:
                log(f"#{conn.id} {kind} upstream connect failed: {e}")
                conn.reset()
                return
            log(f"#{conn.id} {kind} open from {conn.peer[0]}:{conn.peer[1]}")
            await asyncio.gather(self.pump(conn, cr, conn.uw, True), self.pump(conn, conn.ur, cw, False))
        finally:
            self.conns.pop(conn.id, None)
            log(f"#{conn.id} {kind} closed (to LMS {conn.up_bytes} B, to player {conn.down_bytes} B"
                f"{', ' + conn.first_line if conn.first_line else ''})")

    # -- faults ---------------------------------------------------------------
    outage_ended_with_drop = False

    def start_outage(self, secs, scope, after, new):
        o = self.outage
        if o.timer:
            o.timer.cancel()
        o.active, o.scope, o.after, o.new = True, scope, after, new
        o.ends_at = time.time() + secs
        o.cleared.clear()
        self.outage_ended_with_drop = False
        o.timer = asyncio.get_running_loop().call_later(secs, self.end_outage)
        if new == "refuse":
            self.close_listeners(scope)
        log(f"OUTAGE START {secs:g}s scope={scope} after={after} new={new}; "
            f"open: {[c.id for c in self.conns.values() if scope in ('all', c.kind)]}")

    def end_outage(self):
        o = self.outage
        if not o.active:
            return
        if o.timer:
            o.timer.cancel()
            o.timer = None
        caught = [c for c in self.conns.values() if c.frozen]
        o.active = False
        self.outage_ended_with_drop = o.after == "drop"
        if o.after == "drop":
            for c in caught:
                if c.uw is not None:   # held ones reset themselves in handle()
                    c.reset()
        log(f"OUTAGE END after={o.after}; {'reset' if o.after == 'drop' else 'resumed'}: {[c.id for c in caught]}")
        asyncio.ensure_future(self.open_listeners())
        for c in caught:
            if o.after == "resume":
                c.frozen = False
        o.cleared.set()

    def kill(self, scope):
        hit = [c for c in self.conns.values() if scope in ("all", c.kind)]
        for c in hit:
            c.reset()
        log(f"KILL scope={scope}: {[c.id for c in hit]}")

    # -- control --------------------------------------------------------------
    async def control(self, reader, writer):
        try:
            line = (await reader.readline()).decode("latin1")
            while (await reader.readline()) not in (b"\r\n", b"\n", b""):
                pass
            url = urlparse(line.split(" ")[1] if " " in line else "/")
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            scope = q.get("scope", "all")
            if scope not in ("all", "slim", "http"):
                raise ValueError("scope must be all, slim or http")
            if url.path == "/outage":
                after, new = q.get("after", "drop"), q.get("new", "refuse")
                if after not in ("drop", "resume") or new not in ("hold", "refuse"):
                    raise ValueError("after=drop|resume, new=hold|refuse")
                self.start_outage(float(q.get("secs", "30")), scope, after, new)
            elif url.path == "/kill":
                self.kill(scope)
            elif url.path == "/end":
                self.end_outage()
            elif url.path == "/shape":
                self.kbps = max(0, int(q.get("kbps", "0")))
                log(f"SHAPE http download cap {self.kbps} kbit/s" if self.kbps else "SHAPE off")
            elif url.path == "/requests":
                since = float(q.get("since", "0"))
                body = {"now": round(time.time(), 3), "requests": [r for r in self.requests if r["t"] >= since]}
            elif url.path != "/status":
                raise ValueError("paths: /outage /kill /end /status /requests")
            o = self.outage
            if url.path != "/requests":
                body = {"kbps": self.kbps,
                        "outage": {"active": o.active, "scope": o.scope, "after": o.after, "new": o.new,
                                   "remaining_s": round(max(0.0, o.ends_at - time.time()), 1) if o.active else 0},
                        "connections": [c.describe() for c in self.conns.values()]}
            status = "200 OK"
        except Exception as e:
            body, status = {"error": str(e)}, "400 Bad Request"
        data = json.dumps(body, indent=1).encode()
        writer.write(f"HTTP/1.0 {status}\r\nContent-Type: application/json\r\nContent-Length: {len(data)}\r\n\r\n".encode() + data)
        await writer.drain()
        writer.close()

    # Refusing = not listening: the player's connect fails at once (connection
    # refused), with no socket that looks connected for a moment.
    listeners = {}

    def close_listeners(self, scope):
        for kind in list(self.listeners):
            if scope in ("all", kind):
                self.listeners.pop(kind).close()
                log(f"{kind}: not listening (outage)")

    async def open_listeners(self):
        for kind, (listen, upstream) in self.routes.items():
            if kind in self.listeners:
                continue
            for _ in range(20):   # the old socket may take a moment to release the port
                try:
                    self.listeners[kind] = await asyncio.start_server(
                        lambda r, w, k=kind: self.handle(k, r, w), "0.0.0.0", listen, reuse_address=True)
                    break
                except OSError:
                    await asyncio.sleep(0.1)
            log(f"{kind}: :{listen} -> {self.lms_host}:{upstream}")

    async def run(self, ctl_port):
        await self.open_listeners()
        await asyncio.start_server(self.control, "0.0.0.0", ctl_port)
        log(f"control: :{ctl_port}")
        await asyncio.Event().wait()


def ports(s):
    a, b = s.split(":")
    return int(a), int(b)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--lms-host", default="127.0.0.1")
    p.add_argument("--web", type=ports, default=(9011, 9010), help="listen:upstream for web + audio stream")
    p.add_argument("--slim", type=ports, default=(3491, 3490), help="listen:upstream for SlimProto")
    p.add_argument("--ctl", type=int, default=9099)
    a = p.parse_args()
    try:
        asyncio.run(Proxy(a.lms_host, {"http": a.web, "slim": a.slim}).run(a.ctl))
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
