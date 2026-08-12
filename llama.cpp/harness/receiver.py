#!/usr/bin/env python3
"""
receiver.py - dumb sink for benchmark arms pushed from the phone.

Deliberately knows NOTHING about benchmarks. It accepts a framed payload,
verifies its checksum, puts the bytes on disk, and acknowledges. All
interpretation happens later in ingest.py, so a bug in result parsing can
never reject an arm that the device has already deleted.

    python3 receiver.py --inbox out/run_x/inbox --port 9000

Wire protocol (line-framed header, then raw payload):

    ARM <arm_id> <sha256> <nbytes>\\n     followed by exactly <nbytes> bytes
      -> OK <arm_id>\\n            payload stored, checksum verified
      -> ERR <reason>\\n           nothing stored; the device MUST keep its copy

    HB <text...>\\n                       heartbeat, no payload
      -> OK hb\\n

The device is toybox `nc`, which has no half-close (-N), so the length in the
header - not EOF - is what delimits the payload. A truncated transfer is
therefore detected structurally, before the checksum is even considered.
"""

import argparse
import hashlib
import os
import re
import socket
import socketserver
import sys
import tempfile
import time
from pathlib import Path

# arm_id lands in a filename, and it arrives from the network. Anything
# outside this alphabet (notably "/" and "..") is refused rather than
# sanitised - a surprising id means a bug worth seeing, not one to paper over.
ARM_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

MAX_PAYLOAD = 512 * 1024 * 1024     # a capped trace is ~16 MB; 512 MB is slack
SOCKET_TIMEOUT_S = 120              # a stalled peer must not hold a thread


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def recv_exactly(conn, n):
    """Read exactly n bytes, or raise. Never trusts a single recv()."""
    chunks = []
    got = 0
    while got < n:
        b = conn.recv(min(1 << 20, n - got))
        if not b:
            raise ConnectionError(f"peer closed after {got}/{n} bytes")
        chunks.append(b)
        got += len(b)
    return b"".join(chunks)


def recv_header_line(conn, limit=4096):
    """Read one \\n-terminated line without over-reading into the payload."""
    buf = bytearray()
    while b"\n" not in buf:
        if len(buf) > limit:
            raise ValueError("header too long")
        b = conn.recv(1)
        if not b:
            raise ConnectionError("peer closed during header")
        buf += b
    return buf.decode("utf-8", "replace").rstrip("\r\n")


class Handler(socketserver.BaseRequestHandler):

    def handle(self):
        conn = self.request
        conn.settimeout(SOCKET_TIMEOUT_S)
        peer = self.client_address[0]
        try:
            header = recv_header_line(conn)
        except (ConnectionError, ValueError, socket.timeout) as e:
            log(f"{peer}: bad header: {e}")
            return

        parts = header.split()
        if not parts:
            self.reply(b"ERR empty header\n")
            return

        if parts[0] == "PING":
            # liveness probe for address selection; deliberately does NOT
            # update .heartbeat, which is the operator's status line
            self.reply(b"OK ping\n")
            return
        if parts[0] == "HB":
            self.on_heartbeat(peer, header[3:])
            return
        if parts[0] != "ARM":
            self.reply(f"ERR unknown verb {parts[0]!r}\n".encode())
            return
        self.on_arm(peer, parts)

    def reply(self, data):
        try:
            self.request.sendall(data)
        except OSError:
            pass        # peer already gone; its outbox copy survives

    # ---------------------------------------------------------------- verbs

    def on_heartbeat(self, peer, text):
        self.server.heartbeat_path.write_text(
            f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {peer} {text.strip()}\n")
        log(f"HB {text.strip()}")
        self.reply(b"OK hb\n")

    def on_arm(self, peer, parts):
        if len(parts) != 4:
            self.reply(b"ERR expected: ARM <id> <sha256> <nbytes>\n")
            return
        _, arm_id, sha_want, nbytes_s = parts

        if not ARM_ID_RE.match(arm_id):
            log(f"{peer}: refused arm_id {arm_id!r}")
            self.reply(b"ERR bad arm_id\n")
            return
        try:
            nbytes = int(nbytes_s)
        except ValueError:
            self.reply(b"ERR bad length\n")
            return
        if not 0 < nbytes <= MAX_PAYLOAD:
            self.reply(f"ERR length out of range: {nbytes}\n".encode())
            return
        if len(sha_want) != 64 or not re.fullmatch(r"[0-9a-f]{64}", sha_want):
            self.reply(b"ERR bad sha256\n")
            return

        t0 = time.time()
        try:
            payload = recv_exactly(self.request, nbytes)
        except (ConnectionError, socket.timeout) as e:
            # Structural truncation: the device keeps its copy and retries.
            log(f"{peer}: {arm_id} truncated: {e}")
            self.reply(f"ERR truncated: {e}\n".encode())
            return

        sha_got = hashlib.sha256(payload).hexdigest()
        if sha_got != sha_want:
            log(f"{peer}: {arm_id} CHECKSUM MISMATCH")
            self.reply(b"ERR checksum mismatch\n")
            return

        # Land the bytes atomically: a reader of inbox/ must never observe a
        # partially written arm.
        inbox = self.server.inbox
        tmpdir = inbox / ".tmp"
        tmpdir.mkdir(parents=True, exist_ok=True)
        fd, tmpname = tempfile.mkstemp(dir=tmpdir, prefix=f"{arm_id}.")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(payload)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmpname, inbox / f"{arm_id}.tar")
        except OSError as e:
            log(f"{peer}: {arm_id} write failed: {e}")
            Path(tmpname).unlink(missing_ok=True)
            self.reply(f"ERR write failed: {e}\n".encode())
            return

        dt = time.time() - t0
        rate = (nbytes / dt / 1e6) if dt > 0 else 0
        log(f"{peer}: {arm_id} {nbytes/1e6:.1f} MB in {dt:.1f}s "
            f"({rate:.1f} MB/s) OK")
        self.reply(f"OK {arm_id}\n".encode())


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inbox", default="inbox",
                    help="directory to land verified arms in")
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--bind", default="0.0.0.0")
    args = ap.parse_args()

    inbox = Path(args.inbox)
    inbox.mkdir(parents=True, exist_ok=True)

    srv = Server((args.bind, args.port), Handler)
    srv.inbox = inbox
    srv.heartbeat_path = inbox / ".heartbeat"

    log(f"listening on {args.bind}:{args.port} -> {inbox}/")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        srv.shutdown()


if __name__ == "__main__":
    sys.exit(main())
