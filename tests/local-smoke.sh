#!/usr/bin/env bash
# ghost-box local smoke test - the no-kubernetes proof.
#
# boots the real api on localhost, generates a keypair, submits a
# plaintext-marker file as a nacl sealed box, proves:
#   S1  the server accepted the ciphertext
#   S2  the plaintext marker is nowhere on the server side
#   S3  the operator can decrypt offline
#   S4  retention purge erases without a trace
#
# usage: bash tests/local-smoke.sh

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS S$1: $2"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL S$1: $2"; }

command -v python3 >/dev/null || { echo "python3 required"; exit 2; }
python3 -c "import nacl" 2>/dev/null || { echo "pynacl required: pip install pynacl"; exit 2; }

WORK="$(mktemp -d)"
trap 'kill "${SRV_PID:-0}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

PORT=18744
SECRET="$WORK/evidence.txt"
printf 'GHOSTBOX-SMOKE-MARKER-7734: sensitive plaintext never leaves this machine unencrypted\n' > "$SECRET"

echo "== booting api on 127.0.0.1:$PORT =="
GB_SUBMIT_DIR="$WORK/submissions" GB_PORT="$PORT" GB_BIND=127.0.0.1 \
    python3 app/submission_api.py >"$WORK/server.out" 2>&1 &
SRV_PID=$!

for _ in $(seq 1 50); do
    if curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
    sleep 0.2
done
curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null || { echo "api did not come up"; exit 1; }

echo "== keygen =="
python3 tools/keygen.py --out-dir "$WORK/keys" >/dev/null

echo "== submitting through the real client path =="
SUBMIT_OUT="$(python3 client/secure_submit.py \
    --onion "http://127.0.0.1:$PORT/submit" \
    --file "$SECRET" \
    --pubkey-file "$WORK/keys/ghost-box.pub" \
    --no-tor --timeout 30)"
echo "$SUBMIT_OUT"

STORED="$(find "$WORK/submissions" -type f | head -1)"
if [ -n "$STORED" ]; then
    ok 1 "server stored the submission"
else
    bad 1 "no submission file found"
fi

if grep -q "GHOSTBOX-SMOKE-MARKER-7734" "$STORED" 2>/dev/null; then
    bad 2 "plaintext marker FOUND in server storage - encryption failed"
else
    ok 2 "plaintext marker absent from server storage (ciphertext at rest)"
fi

if grep -rq "GHOSTBOX-SMOKE-MARKER-7734" "$WORK/submissions" 2>/dev/null; then
    bad 2b "marker found elsewhere in the submission dir"
else
    ok 2b "no plaintext anywhere in the submission dir"
fi

if python3 tools/decrypt.py --key-file "$WORK/keys/ghost-box.key" --file "$STORED" | grep -q "GHOSTBOX-SMOKE-MARKER-7734"; then
    ok 3 "operator offline decrypt round-trips the plaintext"
else
    bad 3 "decrypted output does not match"
fi

ERASED="$(SMOKE_DIR="$WORK/submissions" python3 - <<'PY'
import sys, os
sys.path.insert(0, "app")
import submission_api as s
s.SUBMIT_DIR = os.environ["SMOKE_DIR"]
print(s._purge_expired(0.00001))
PY
)"
if [ "$ERASED" -ge 1 ] && [ -z "$(find "$WORK/submissions" -type f)" ]; then
    ok 4 "retention purge erased storage with no residue"
else
    bad 4 "purge left residue (erased=$ERASED)"
fi

if grep -qi "marker\|evidence" "$WORK/server.out" 2>/dev/null; then
    bad 5 "server stdout leaked submission details"
else
    ok 5 "server stdout is silent about submissions"
fi

echo
echo "smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
