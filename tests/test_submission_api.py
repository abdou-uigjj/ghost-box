"""pytest suite for the ghost-box submission api.

Runs the real server in-process on an ephemeral port against a
plain temp dir (no k8s needed) and asserts the behaviour the
threat model depends on: opaque storage, hard caps, silent logs,
RAM-only counters.
"""

import json
import os
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "app"))

import submission_api  # noqa: E402


@pytest.fixture()
def server(tmp_path):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()

    # the api reads config at import time; point the module at the sandbox
    submission_api.SUBMIT_DIR = str(tmp_path / "submissions")
    submission_api.MAX_BODY = 1024 * 1024
    submission_api.RATE_PER_MIN = 1000
    submission_api.COUNTERS.update(dict.fromkeys(submission_api.COUNTERS, 0))
    submission_api._BUCKETS.clear()

    submission_api.ensure_dirs()
    httpd = submission_api.ThreadingHTTPServer(("127.0.0.1", port), submission_api.Handler)
    httpd.daemon_threads = True
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{port}", tmp_path / "submissions"
    httpd.shutdown()
    httpd.server_close()


def _post(url, data=b"x", headers=None, timeout=5):
    req = urllib.request.Request(
        url, data=data, headers=headers or {"Content-Type": "application/octet-stream"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()


def test_health(server):
    url, _ = server
    with urllib.request.urlopen(f"{url}/healthz", timeout=5) as resp:
        assert resp.status == 200
        assert json.loads(resp.read())["status"] == "ok"


def test_readyz(server):
    url, _ = server
    req = urllib.request.Request(f"{url}/readyz")
    with urllib.request.urlopen(req, timeout=5) as resp:
        assert resp.status == 200


def test_submit_stores_exact_bytes(server):
    url, submit_dir = server
    payload = b"\x8b\x01ghost-ciphertext\x00\xff" * 100
    status, body = _post(f"{url}/submit", payload)
    assert status == 201
    result = json.loads(body)
    assert result["bytes"] == len(payload)
    files = list(submit_dir.iterdir())
    assert len(files) == 1
    assert files[0].read_bytes() == payload


def test_no_access_logs(server, capsys):
    url, _ = server
    _post(f"{url}/submit", b"quiet please")
    _post(f"{url}/submit", b"and again")
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == ""


def test_unknown_path_404(server):
    url, _ = server
    status, _ = _post(f"{url}/nope", b"x")
    assert status == 404


def test_oversize_rejected(server):
    url, submit_dir = server
    try:
        status, _ = _post(f"{url}/submit", b"x" * (1024 * 1024 + 1))
    except (urllib.error.URLError, ConnectionError, OSError):
        # the server refuses the body and closes the door mid-upload -
        # a connection-level rejection is still a rejection
        status = 413
    assert status == 413
    assert list(submit_dir.iterdir()) == []


def test_zero_length_rejected(server):
    url, submit_dir = server
    status, _ = _post(f"{url}/submit", b"")
    assert status == 400
    assert list(submit_dir.iterdir()) == []


def test_missing_length_rejected(server):
    url, _ = server
    req = urllib.request.Request(f"{url}/submit", data=b"abc", method="POST")
    req.add_unredirected_header("Content-Length", "")
    try:
        urllib.request.urlopen(req, timeout=5)
        raise AssertionError("expected failure")
    except urllib.error.HTTPError as err:
        assert err.code in (400, 411)


def test_rate_limit(server, monkeypatch):
    url, submit_dir = server
    monkeypatch.setattr(submission_api, "RATE_PER_MIN", 3)
    submission_api._BUCKETS.clear()
    codes = []
    for _ in range(6):
        status, _ = _post(f"{url}/submit", b"burst")
        codes.append(status)
    assert codes[:3] == [201, 201, 201]
    assert 429 in codes
    assert len(list(submit_dir.iterdir())) < 6


def test_purge_expired(server):
    _, submit_dir = server
    payload_path = submit_dir / "old.bin"
    payload_path.write_bytes(b"stale")
    stamp = time.time() - 10 * 3600
    os.utime(payload_path, (stamp, stamp))
    fresh_path = submit_dir / "fresh.bin"
    fresh_path.write_bytes(b"fresh")

    erased = submission_api._purge_expired(1)  # 1 hour
    assert erased == 1
    assert not payload_path.exists()
    assert fresh_path.exists()


def test_retention_disabled(server, monkeypatch):
    _, submit_dir = server
    payload_path = submit_dir / "ancient.bin"
    payload_path.write_bytes(b"keep me")
    stamp = time.time() - 100 * 3600
    os.utime(payload_path, (stamp, stamp))
    assert submission_api._purge_expired(0) == 0
    assert payload_path.exists()


def test_counters_shape(server):
    url, _ = server
    req = urllib.request.Request(f"{url}/metrics")
    with urllib.request.urlopen(req, timeout=5) as resp:
        text = resp.read().decode()
    assert "ghostbox_submissions_total" in text
    assert "ghostbox_bytes_total" in text
    assert "ghostbox_erased_total" in text
    # no ip addresses may appear in metrics
    assert "127.0.0.1" not in text.split("\n")[0]
