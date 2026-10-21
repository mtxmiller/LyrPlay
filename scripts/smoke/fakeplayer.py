#!/usr/bin/env python3
"""A silent SlimProto player, so the rig can build a sync group (outage.py P8).

It registers with LMS like squeezelite (HELO, device 12) and answers the
server the way a player with an instant, bottomless buffer would: STMc +
STMl on strm 's', STMs at once (or on 'u' when LMS holds the start for the
group), STMd two seconds later, STMt with the elapsed time on every poll.
It never opens the audio stream: LMS's state machine runs on STAT only.

    python3 fakeplayer.py [--host 127.0.0.1] [--port 3490] [--mac 02:00:00:00:99:98] [--name "SmokeTest Fake"]

Run it on the host that reaches the LMS (ser5 for lms-test); macOS may keep
python3 off the LAN.
"""
import argparse
import socket
import struct
import threading
import time

T0 = time.time()


def log(*a):
    print(f"{time.strftime('%H:%M:%S')} [{time.time() - T0:8.2f}]", *a, flush=True)


class Player:
    def __init__(self, sock, mac, name):
        self.sock = sock
        self.mac = bytes(int(x, 16) for x in mac.split(":"))
        self.name = name
        self.lock = threading.Lock()
        self.started_at = None      # wall clock when the current song "started playing"
        self.paused_elapsed = None
        self.generation = 0

    def elapsed(self):
        if self.paused_elapsed is not None:
            return self.paused_elapsed
        return time.time() - self.started_at if self.started_at else 0.0

    def send(self, opcode, payload):
        with self.lock:
            self.sock.sendall(opcode + struct.pack(">I", len(payload)) + payload)

    def stat(self, event, server_timestamp=0):
        elapsed = self.elapsed()
        jiffies = int((time.time() - T0) * 1000) & 0xFFFFFFFF
        payload = struct.pack(">4sBBBIIIIHIIIIHIIH", event.encode(), 0, ord("m"), 0,
                              2 * 1024 * 1024, 0, 0, 0, 0, jiffies, 3528000, 1764000,
                              int(elapsed), 0, int(elapsed * 1000) & 0xFFFFFFFF, server_timestamp, 0)
        self.send(b"STAT", payload)

    def helo(self):
        caps = b"Model=squeezelite,ModelName=SqueezeLite,AccuratePlayPoints=1,MaxSampleRate=48000,mp3,flc,ogg,ops,pcm"
        payload = struct.pack(">BB6s16sHII2s", 12, 0, self.mac, b"\0" * 16, 0, 0, 0, b"en") + caps
        self.send(b"HELO", payload)

    def decode_done_later(self, generation):
        time.sleep(2)
        if generation == self.generation:
            self.stat("STMd")

    def start_playing(self):
        self.started_at = time.time()
        self.paused_elapsed = None
        self.stat("STMs")

    def strm(self, payload):
        command = chr(payload[0])
        autostart = chr(payload[1])
        timestamp = struct.unpack(">I", payload[14:18])[0]
        if command == "t":
            self.stat("STMt", timestamp)
        elif command == "s":
            self.generation += 1
            log(f"strm s autostart={autostart}")
            self.stat("STMc")
            self.stat("STMl")
            if autostart in ("1", "3"):
                self.start_playing()
            threading.Thread(target=self.decode_done_later, args=(self.generation,), daemon=True).start()
        elif command == "u":
            log("strm u")
            if self.paused_elapsed is not None and self.started_at:
                self.started_at = time.time() - self.paused_elapsed
                self.paused_elapsed = None
                self.stat("STMr")
            else:
                self.stat("STMr")
                self.start_playing()
        elif command == "p":
            log("strm p")
            self.paused_elapsed = self.elapsed()
            self.stat("STMp")
        elif command in ("q", "f"):
            log(f"strm {command}")
            self.generation += 1
            self.started_at = None
            self.paused_elapsed = None
            self.stat("STMf")

    def setd(self, payload):
        if payload[:1] == b"\0" and len(payload) == 1:   # name query
            self.send(b"SETD", b"\0" + self.name.encode() + b"\0")

    def run(self):
        self.helo()
        buf = b""
        while True:
            data = self.sock.recv(65536)
            if not data:
                log("server closed the connection")
                return
            buf += data
            while len(buf) >= 2:
                length = struct.unpack(">H", buf[:2])[0]
                if len(buf) < 2 + length:
                    break
                frame, buf = buf[2:2 + length], buf[2 + length:]
                opcode, payload = frame[:4], frame[4:]
                if opcode == b"strm" and len(payload) >= 24:
                    self.strm(payload)
                elif opcode == b"setd":
                    self.setd(payload)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=3490)
    p.add_argument("--mac", default="02:00:00:00:99:98")
    p.add_argument("--name", default="SmokeTest Fake")
    a = p.parse_args()
    sock = socket.create_connection((a.host, a.port))
    log(f"connected to {a.host}:{a.port} as {a.mac}")
    Player(sock, a.mac, a.name).run()


if __name__ == "__main__":
    main()
