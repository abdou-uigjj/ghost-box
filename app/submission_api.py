#!/usr/bin/env python3
"""ghost-box submission API.

Accepts client-encrypted submissions and stores them in RAM only.
The server never holds a private key, never logs an IP address and
never writes a byte to a persistent volume. When the pod dies the
kernel reclaims the tmpfs pages and every submission is gone.

Design rules this file is not allowed to break:
  * stdlib only - no pip dependencies, no supply chain
  * no access logs (pod logs land on the node disk via kubelet)
  * no client metadata persisted anywhere, not even in memory
  * every writable byte lives under the tmpfs submission dir
"""

import ipaddress
import json
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("GB_BIND", "0.0.0.0")
PORT = int(os.environ.get("GB_PORT", "8080"))
SUBMIT_DIR = os.environ.get("GB_SUBMIT_DIR", "/dev/shm/submissions")
MAX_BODY = int(os.environ.get("GB_MAX_BODY_MB", "20")) * 1024 * 1024
RATE_PER_MIN = int(os.environ.get("GB_RATE_PER_MIN", "30"))
RETENTION_HOURS = float(os.environ.get("GB_RETENTION_HOURS", "24"))

STARTED = time.time()
LOCK = threading.Lock()
COUNTERS = {
    "submissions_total": 0,
    "bytes_total": 0,
    "rejected_total": 0,
    "rate_limited_total": 0,
    "erased_total": 0,
}

# token bucket per source ip, purely in memory, never persisted
_BUCKETS = {}


def ensure_dirs():
    """Create the RAM submission directory with tight permissions."""
    os.makedirs(SUBMIT_DIR, mode=0o700, exist_ok=True)
    os.chmod(SUBMIT_DIR, 0o700)


def counter(name, amount=1):
    with LOCK:
        COUNTERS[name] = COUNTERS.get(name, 0) + amount


def _purge_expired(max_age_hours):
    """Delete submissions older than max_age_hours. Returns erased count."""
    if max_age_hours <= 0:
        return 0
    cutoff = time.time() - max_age_hours * 3600
    erased = 0
    try:
        names = os.listdir(SUBMIT_DIR)
    except OSError:
        return 0
    for name in names:
        path = os.path.join(SUBMIT_DIR, name)
        try:
            if os.stat(path).st_mtime < cutoff:
                os.unlink(path)
                erased += 1
        except OSError:
            continue
    if erased:
        counter("erased_total", erased)
    return erased


def _janitor():
    while True:
        time.sleep(60)
        _purge_expired(RETENTION_HOURS)


def _allow_rate(ip):
    """Token bucket. Capacity = RATE_PER_MIN, refill RATE_PER_MIN per minute."""
    now = time.monotonic()
    with LOCK:
        tokens, last = _BUCKETS.get(ip, (float(RATE_PER_MIN), now))
        tokens = min(float(RATE_PER_MIN), tokens + (now - last) * RATE_PER_MIN / 60.0)
        if tokens < 1.0:
            _BUCKETS[ip] = (tokens, now)
            return False
        _BUCKETS[ip] = (tokens - 1.0, now)
        return True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def version_string(self):  # do not leak the python version
        return "ghost-box"

    def log_message(self, fmt, *args):  # no access logs, period
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, {"status": "ok"})
        elif self.path == "/readyz":
            if os.path.isdir(SUBMIT_DIR) and os.access(SUBMIT_DIR, os.W_OK):
                self._send(200, {"status": "ready"})
            else:
                self._send(503, {"status": "not-ready"})
        elif self.path == "/metrics":
            with LOCK:
                snapshot = dict(COUNTERS)
            lines = [
                "# ghost-box runtime counters (memory only)",
                f"ghostbox_uptime_seconds {int(time.time() - STARTED)}",
            ]
            for key, value in snapshot.items():
                lines.append(f"ghostbox_{key} {value}")
            body = ("\n".join(lines) + "\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            counter("rejected_total")
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/submit":
            counter("rejected_total")
            self._send(404, {"error": "not found"})
            return

        peer = self.client_address[0]
        try:
            ip = ipaddress.ip_address(peer.split("%")[0])
            if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
                ip = ip.ipv4_mapped
            bucket_ip = str(ip)
        except ValueError:
            bucket_ip = peer

        if not _allow_rate(bucket_ip):
            counter("rate_limited_total")
            counter("rejected_total")
            self._send(429, {"error": "slow down"})
            return

        length = self.headers.get("Content-Length")
        if length is None:
            counter("rejected_total")
            self._send(411, {"error": "content-length required"})
            return
        try:
            length = int(length)
        except ValueError:
            counter("rejected_total")
            self._send(400, {"error": "bad content-length"})
            return
        if length <= 0:
            counter("rejected_total")
            self._send(400, {"error": "empty submission"})
            return
        if length > MAX_BODY:
            counter("rejected_total")
            self._send(413, {"error": "submission too large"})
            return

        name = secrets.token_hex(16) + ".bin"
        path = os.path.join(SUBMIT_DIR, name)
        remaining = length
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as out:
                while remaining > 0:
                    chunk = self.rfile.read(min(65536, remaining))
                    if not chunk:
                        raise IOError("client disconnect")
                    out.write(chunk)
                    remaining -= len(chunk)
        except OSError:
            counter("rejected_total")
            try:
                os.unlink(path)
            except OSError:
                pass
            self._send(500, {"error": "storage failure"})
            return

        # one request per connection keeps framing simple and stateless
        self.close_connection = True
        counter("submissions_total")
        counter("bytes_total", length)
        self._send(201, {"status": "accepted", "id": name[:12], "bytes": length})


def main():
    ensure_dirs()
    if RETENTION_HOURS > 0:
        threading.Thread(target=_janitor, daemon=True).start()
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    server.daemon_threads = True
    print(f"ghost-box listening on {BIND}:{PORT}, storing in {SUBMIT_DIR} (RAM only)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
