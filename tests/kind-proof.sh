#!/usr/bin/env bash
# ghost-box cluster proof - runs inside CI against a real kind cluster
# with calico enforcing policy. every assertion is observable, not
# documented-and-hoped-for.
#
#   P1  workloads ready
#   P2  no persistent volumes and no statefulsets in ghost-box
#   P3  submission storage is tmpfs (in the running pod)
#   P4  tor state is tmpfs
#   P5  a v3 onion address is published
#   P6  cross-namespace probe is dropped by policy
#   P7  same-namespace non-tor probe is dropped by policy
#   P8  the only allowed path (tor -> api) accepts a submission
#   P9  plaintext marker lands in pod RAM (storage really works)
#  P10  api root filesystem is read-only
#  P11  ciphertext-at-rest: sealed-box submission stores no plaintext
#  P12  metrics are consistent with the traffic (and leak no ips)
#  P13  killing the api pod erases every submission (memory reclaimed)
#  P14  killing the tor pod burns the onion address (rotation)
#
# usage: bash tests/kind-proof.sh

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

NS=ghost-box
MARKER_PLAIN="GHOSTBOX-NETPOL-MARKER-5591"
MARKER_CIPHER="GHOSTBOX-CIPHER-MARKER-9151"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS P$1: $2"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL P$1: $2"; }
die() { echo "fatal: $*"; exit 2; }

command -v kubectl >/dev/null || die "kubectl not found"
command -v curl >/dev/null || die "curl not found"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# helper: current tor pod name (fresh each call - tor restarts are expected)
# ---------------------------------------------------------------------------
tor_pod() {
    kubectl -n "$NS" get pod -l app=tor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

tor_dump() { # on failure: show why tor restarted
    kubectl -n "$NS" get pods -l app=tor -o wide || true
    kubectl -n "$NS" logs deploy/tor --tail=60 -p 2>/dev/null || true
    kubectl -n "$NS" logs deploy/tor --tail=20 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# helper: run a command inside a throwaway busybox pod, return its exit code
# ---------------------------------------------------------------------------
probe() { # probe <ns> <name> <sh-cmd>
    local ns="$1" name="$2" cmd="$3" rc="" uid
    uid="-$RANDOM"
    name="$name$uid"
    # pod is fully compliant with the restricted pod security standard
    if ! kubectl -n "$ns" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: busybox:1.36
      command: ["/bin/sh", "-c"]
      args: ["$cmd"]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
EOF
    then
        die "probe pod $name rejected by admission policy - fix the probe"
    fi
    if kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded \
        "pod/$name" --timeout=60s >/dev/null 2>&1; then
        echo 0
        return 0
    fi
    # blocked commands exit nonzero -> phase Failed; wait for it fast
    kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Failed \
        "pod/$name" --timeout=20s >/dev/null 2>&1 || true
    rc="$(kubectl -n "$ns" get pod "$name" \
        -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)"
    echo "${rc:-running}"
    return 0
}

# ---------------------------------------------------------------------------
echo "== P1 workloads ready =="
if kubectl -n "$NS" rollout status deploy/submission-api --timeout=180s >/dev/null &&
    kubectl -n "$NS" rollout status deploy/tor --timeout=180s >/dev/null; then
    ok 1 "submission-api and tor are ready"
else
    bad 1 "workloads did not become ready"
    kubectl -n "$NS" get pods -o wide || true
    kubectl -n "$NS" logs deploy/tor --tail=40 || true
    kubectl -n "$NS" logs deploy/submission-api --tail=20 || true
fi

# ---------------------------------------------------------------------------
echo "== P2 no persistent volumes, no statefulsets =="
PVC_COUNT="$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | wc -l | tr -d ' ')"
STS_COUNT="$(kubectl -n "$NS" get statefulset --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "$PVC_COUNT" -eq 0 ] && [ "$STS_COUNT" -eq 0 ]; then
    ok 2 "zero PVCs and zero StatefulSets in $NS"
else
    bad 2 "pvc=$PVC_COUNT sts=$STS_COUNT - persistent state exists"
fi

# ---------------------------------------------------------------------------
echo "== P3 submission storage is tmpfs =="
API_POD="$(kubectl -n "$NS" get pod -l app=submission-api -o jsonpath='{.items[0].metadata.name}')"
[ -n "$API_POD" ] || die "no api pod"
if kubectl -n "$NS" exec "$API_POD" -- sh -c \
    "grep ' /dev/shm ' /proc/mounts | grep -w tmpfs" >/dev/null 2>&1; then
    ok 3 "/dev/shm is tmpfs inside the running api pod"
else
    bad 3 "/dev/shm is NOT tmpfs inside the api pod"
fi

# ---------------------------------------------------------------------------
echo "== P4 tor state is tmpfs =="
TOR_POD="$(tor_pod)"
[ -n "$TOR_POD" ] || die "no tor pod"
if kubectl -n "$NS" exec "$TOR_POD" -- sh -c \
    "grep ' /dev/shm ' /proc/mounts | grep -w tmpfs" >/dev/null 2>&1; then
    ok 4 "/dev/shm is tmpfs inside the tor pod (keys live in RAM)"
else
    bad 4 "/dev/shm is NOT tmpfs inside the tor pod"
fi

# ---------------------------------------------------------------------------
echo "== P5 onion v3 address published =="
OLD_ONION=""
for _ in $(seq 1 30); do
    OLD_ONION="$(kubectl -n "$NS" exec "$TOR_POD" -- cat /dev/shm/tor/hs/hostname 2>/dev/null | tr -d '\r\n' || true)"
    [ -n "$OLD_ONION" ] && break
    sleep 2
done
if echo "$OLD_ONION" | grep -Eq '^[a-z2-7]{56}\.onion$'; then
    ok 5 "v3 onion address published (length and charset valid)"
else
    bad 5 "onion address missing or malformed: '$OLD_ONION'"
fi

# ---------------------------------------------------------------------------
echo "== P6 cross-namespace access is dropped =="
RC="$(probe default probe-external \
    "wget -T 3 -q -O /dev/null http://submission-api.$NS.svc.cluster.local:80/healthz")"
if [ "$RC" != "0" ]; then
    ok 6 "pod outside ghost-box cannot reach the api (rc=$RC)"
else
    bad 6 "cross-namespace traffic reached the api - default-deny is broken"
fi

# ---------------------------------------------------------------------------
echo "== P7 lateral movement inside ghost-box is dropped =="
RC="$(probe "$NS" probe-insider \
    "wget -T 3 -q -O /dev/null http://submission-api:80/healthz")"
if [ "$RC" != "0" ]; then
    ok 7 "non-tor pod inside ghost-box cannot reach the api (rc=$RC)"
else
    bad 7 "insider pod reached the api - ingress policy is broken"
fi

# ---------------------------------------------------------------------------
echo "== P8 allowed path tor -> api accepts a submission =="
RESP="$(kubectl -n "$NS" exec "$(tor_pod)" -- curl -s -m 10 \
    --data-binary "$MARKER_PLAIN" -H 'Content-Type: application/octet-stream' \
    http://submission-api/submit || true)"
if echo "$RESP" | grep -q '"accepted"'; then
    ok 8 "tor -> api path accepted a submission"
else
    bad 8 "allowed path failed: '$RESP'"
    tor_dump
fi

# ---------------------------------------------------------------------------
echo "== P9 plaintext marker really landed in pod RAM =="
FOUND=0
for pod in $(kubectl -n "$NS" get pod -l app=submission-api -o jsonpath='{.items[*].metadata.name}'); do
    if kubectl -n "$NS" exec "$pod" -- sh -c \
        "grep -rl '$MARKER_PLAIN' /dev/shm/submissions 2>/dev/null" | grep -q .; then
        FOUND=1
    fi
done
if [ "$FOUND" -eq 1 ]; then
    ok 9 "submission stored in tmpfs while pod is alive"
else
    bad 9 "marker not found in tmpfs - storage path is broken"
fi

# ---------------------------------------------------------------------------
echo "== P10 api root filesystem is read-only =="
if kubectl -n "$NS" exec "$API_POD" -- sh -c "touch /etc/ghost-box-ro-test 2>/dev/null"; then
    bad 10 "wrote to the container root filesystem - readOnlyRootFilesystem is off"
else
    ok 10 "root filesystem refuses writes"
fi

# ---------------------------------------------------------------------------
echo "== P11 ciphertext at rest - server never sees plaintext =="
python3 tools/keygen.py --out-dir "$WORK/keys" >/dev/null
printf '%s: top secret content that must never appear on the server\n' "$MARKER_CIPHER" > "$WORK/secret.txt"
python3 - "$WORK" <<'PY'
import sys
sys.path.insert(0, "client")
sys.path.insert(0, ".")
from secure_submit import encrypt_file
work = sys.argv[1]
with open(f"{work}/keys/ghost-box.pub", encoding="utf-8") as fh:
    pubkey_b64 = fh.read().strip()
import base64
ct = encrypt_file(f"{work}/secret.txt", base64.b64decode(pubkey_b64))
with open(f"{work}/sealed.bin", "wb") as out:
    out.write(ct)
print(f"sealed {len(ct)} bytes")
PY
kubectl -n "$NS" port-forward deploy/submission-api 18443:8080 >/dev/null 2>&1 &
PF_PID=$!
sleep 2
RESP="$(curl -s -m 15 --data-binary @"$WORK/sealed.bin" \
    -H 'Content-Type: application/octet-stream' http://127.0.0.1:18443/submit || true)"
kill "$PF_PID" 2>/dev/null || true
if ! echo "$RESP" | grep -q '"accepted"'; then
    bad 11 "sealed submission failed: '$RESP'"
else
    FOUND=0
    for pod in $(kubectl -n "$NS" get pod -l app=submission-api -o jsonpath='{.items[*].metadata.name}'); do
        if kubectl -n "$NS" exec "$pod" -- sh -c \
            "grep -rl '$MARKER_CIPHER' /dev/shm/submissions 2>/dev/null" | grep -q .; then
            FOUND=1
        fi
    done
    if [ "$FOUND" -eq 0 ]; then
        ok 11 "sealed-box accepted and plaintext marker absent from storage"
    else
        bad 11 "PLAINTEXT FOUND in storage - client-side encryption is broken"
    fi
fi

# ---------------------------------------------------------------------------
echo "== P12 metrics consistent and metadata-free =="
METRICS="$(kubectl -n "$NS" exec "$(tor_pod)" -- curl -s -m 10 http://submission-api/metrics || true)"
SUBMITTED="$(echo "$METRICS" | grep '^ghostbox_submissions_total' | awk '{print $2}')"
if [ "${SUBMITTED:-0}" -ge 2 ]; then
    ok 12 "metrics report $SUBMITTED submissions (>= 2 sent)"
else
    bad 12 "metrics inconsistent: '$SUBMITTED'"
    tor_dump
fi
if echo "$METRICS" | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    bad 12b "metrics leak an ip address"
else
    ok 12b "metrics contain no ip addresses"
fi

# ---------------------------------------------------------------------------
echo "== P13 killing the api pod erases every submission =="
kubectl -n "$NS" delete pod "$API_POD" --force --grace-period=0 >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/submission-api --timeout=180s >/dev/null
API_POD2="$(kubectl -n "$NS" get pod -l app=submission-api -o jsonpath='{.items[0].metadata.name}')"
LEFT="$(kubectl -n "$NS" exec "$API_POD2" -- sh -c \
    "ls -A /dev/shm/submissions 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ')"
if [ "${LEFT:-1}" -eq 0 ]; then
    ok 13 "fresh pod holds zero submissions - memory was reclaimed by the kernel"
else
    bad 13 "submissions survived pod death (left=$LEFT) - storage is NOT ram-only"
fi

# ---------------------------------------------------------------------------
echo "== P14 killing the tor pod burns the onion address =="
kubectl -n "$NS" delete pod "$(tor_pod)" --force --grace-period=0 >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/tor --timeout=180s >/dev/null
TOR_POD2="$(kubectl -n "$NS" get pod -l app=tor -o jsonpath='{.items[0].metadata.name}')"
NEW_ONION=""
for _ in $(seq 1 30); do
    NEW_ONION="$(kubectl -n "$NS" exec "$TOR_POD2" -- cat /dev/shm/tor/hs/hostname 2>/dev/null | tr -d '\r\n' || true)"
    [ -n "$NEW_ONION" ] && break
    sleep 2
done
if [ -n "$NEW_ONION" ] && [ "$NEW_ONION" != "$OLD_ONION" ]; then
    ok 14 "onion address rotated after tor restart (burner identity confirmed)"
else
    bad 14 "onion address did not rotate (old=$OLD_ONION new=$NEW_ONION)"
fi

# ---------------------------------------------------------------------------
echo
echo "cluster proof: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
