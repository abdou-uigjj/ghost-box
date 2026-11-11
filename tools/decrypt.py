#!/usr/bin/env python3
"""operator-side decryption for ghost-box submissions.

Run OFFLINE, on the machine holding ghost-box.key:

    python3 decrypt.py --key-file keys/ghost-box.key \
        --file <submission.bin> --out evidence.zip

Writes to a file only with --out; without it the plaintext goes to
stdout so nothing lands on disk unless you ask for it.
"""

import argparse
import base64
import sys

from nacl.public import PrivateKey, SealedBox


def main():
    parser = argparse.ArgumentParser(description="decrypt a ghost-box submission")
    parser.add_argument("--key-file", required=True, help="path to ghost-box.key")
    parser.add_argument("--file", required=True, help="ciphertext to decrypt")
    parser.add_argument("--out", help="output path (omit to write to stdout)")
    args = parser.parse_args()

    try:
        with open(args.key_file, encoding="utf-8") as fh:
            key = PrivateKey(base64.b64decode(fh.read().strip(), validate=True))
    except (OSError, ValueError) as exc:
        print(f"error: cannot load key: {exc}", file=sys.stderr)
        return 2

    try:
        with open(args.file, "rb") as fh:
            ciphertext = fh.read()
        plaintext = SealedBox(key).decrypt(ciphertext)
    except (OSError, ValueError):
        print("error: cannot read submission", file=sys.stderr)
        return 2
    except Exception:  # noqa: BLE001 - wrong key or tampered ciphertext
        print("error: decryption failed (wrong key or corrupted data)", file=sys.stderr)
        return 3

    if args.out:
        fd_out = open(args.out, "wb")  # noqa: SIM115 - closed below
        try:
            fd_out.write(plaintext)
        finally:
            fd_out.close()
        print(f"decrypted {len(plaintext)} bytes to {args.out}")
    else:
        sys.stdout.buffer.write(plaintext)
    return 0


if __name__ == "__main__":
    sys.exit(main())
