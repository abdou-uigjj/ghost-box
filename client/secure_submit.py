#!/usr/bin/env python3
"""ghost-box client - submit a file through tor without leaving a trace.

The file is encrypted on THIS machine with the operator's public key
(NaCl sealed box) before a single byte leaves. The server receives
ciphertext it cannot open. Usage:

    python3 secure_submit.py --onion http://<address>.onion/submit \
        --file evidence.zip --pubkey-file operator.pub

Requires tor running locally (socks5 on 127.0.0.1:9050) unless
--no-tor is passed for lab testing.
"""

import argparse
import base64
import sys
from urllib.request import Request, urlopen

MAX_SIZE = 20 * 1024 * 1024


def fail(msg, code=2):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(code)


def load_pubkey(args):
    try:
        if args.pubkey:
            raw = args.pubkey
        else:
            with open(args.pubkey_file, encoding="utf-8") as fh:
                raw = fh.read().strip()
        key = base64.b64decode(raw, validate=True)
        if len(key) != 32:
            raise ValueError("key must be 32 raw bytes")
        return key
    except (OSError, ValueError) as exc:
        fail(f"cannot load public key: {exc}")
    return None  # pragma: no cover


def setup_socks(proxy):
    import socket

    import socks

    host, _, port = proxy.partition(":")
    socks.set_default_proxy(
        socks.SOCKS5, host or "127.0.0.1", int(port or "9050"), rdns=True
    )
    socket.socket = socks.socksocket


def encrypt_file(path, pubkey):
    from nacl.public import PublicKey, SealedBox

    try:
        with open(path, "rb") as fh:
            plaintext = bytearray(fh.read(MAX_SIZE + 1))
    except OSError as exc:
        fail(f"cannot read input file: {exc}")
    if not plaintext:
        fail("input file is empty")
    if len(plaintext) > MAX_SIZE:
        fail("file larger than the 20 MiB limit")
    ciphertext = SealedBox(PublicKey(pubkey)).encrypt(bytes(plaintext))
    for i in range(len(plaintext)):  # best-effort local wipe
        plaintext[i] = 0
    del plaintext
    return ciphertext


def submit(url, ciphertext, timeout):
    req = Request(  # noqa: S310 - onion http, tls makes no sense on hidden services
        url,
        data=ciphertext,
        headers={"Content-Type": "application/octet-stream"},
        method="POST",
    )
    with urlopen(req, timeout=timeout) as resp:  # noqa: S310
        body = resp.read().decode()
        return resp.status, body


def main():
    parser = argparse.ArgumentParser(description="ghost-box secure submission client")
    parser.add_argument("--onion", required=True, help="full submit url, http://<addr>.onion/submit")
    parser.add_argument("--file", required=True, help="file to submit")
    parser.add_argument("--pubkey", help="operator public key, base64 (or use --pubkey-file)")
    parser.add_argument("--pubkey-file", help="file holding the base64 public key")
    parser.add_argument("--socks", default="127.0.0.1:9050", help="tor socks5 proxy (default 127.0.0.1:9050)")
    parser.add_argument("--no-tor", action="store_true", help="skip tor (lab testing only)")
    parser.add_argument("--timeout", type=int, default=120, help="transfer timeout seconds")
    args = parser.parse_args()

    if not args.pubkey and not args.pubkey_file:
        fail("provide --pubkey or --pubkey-file")

    pubkey = load_pubkey(args)
    ciphertext = encrypt_file(args.file, pubkey)

    if not args.no_tor:
        try:
            setup_socks(args.socks)
        except ImportError:
            fail("pysocks is required for tor mode: pip install pysocks")

    try:
        status, body = submit(args.onion, ciphertext, args.timeout)
    except Exception as exc:  # connection, proxy, timeout
        fail(f"submission failed: {exc}")

    if status == 201:
        print("submitted")
        print(body)
    else:
        fail(f"server replied {status}: {body}")


if __name__ == "__main__":
    main()
