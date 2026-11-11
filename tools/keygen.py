#!/usr/bin/env python3
"""operator-side keypair generator for ghost-box.

Run this ONCE, offline, on a machine you trust:

    python3 keygen.py --out-dir keys/

Writes ghost-box.key (private, 0600) and ghost-box.pub (public, 0644)
into the output directory. The private key never touches ghost-box
servers - they physically cannot decrypt submissions.
"""

import argparse
import base64
import os
import sys

from nacl.public import PrivateKey


def main():
    parser = argparse.ArgumentParser(description="generate a ghost-box operator keypair")
    parser.add_argument("--out-dir", default=".", help="directory for the key files")
    args = parser.parse_args()

    key = PrivateKey.generate()

    os.makedirs(args.out_dir, mode=0o700, exist_ok=True)
    priv_path = os.path.join(args.out_dir, "ghost-box.key")
    pub_path = os.path.join(args.out_dir, "ghost-box.pub")

    priv_b64 = base64.b64encode(bytes(key)).decode()
    pub_b64 = base64.b64encode(bytes(key.public_key)).decode()

    fd = os.open(priv_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(priv_b64 + "\n")
    os.chmod(priv_path, 0o600)

    with open(pub_path, "w", encoding="utf-8") as fh:
        fh.write(pub_b64 + "\n")
    os.chmod(pub_path, 0o644)

    print(f"public key  (publish out-of-band): {pub_b64}")
    print(f"public key file:                   {pub_path}")
    print(f"private key file (keep offline):   {priv_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
