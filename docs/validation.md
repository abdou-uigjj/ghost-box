# ghost-box validation guide

Every guarantee the README makes is asserted somewhere mechanical. This
document maps claim -> proof and tells you how to reproduce each layer
without CI.

## layer 1: policy-as-code (every push)

`conftest test k8s/ --policy policy/` runs four Rego packs against every
manifest:

| pack | rejects |
|---|---|
| `001-no-persistent-storage.rego` | PVCs, CSI volumes, StatefulSets, PVC mounts |
| `002-tmpfs-only.rego` | hostPath, disk-backed emptyDir, memory emptyDir without sizeLimit |
| `003-pod-hardening.rego` | root containers, privilege escalation, writable rootfs, missing caps drop, missing seccomp, missing limits, `:latest` images |
| `004-network-shape.rego` | LoadBalancer / NodePort / Ingress in the namespace |

Reproduce locally:

```bash
conftest test k8s/ --policy policy/
```

A manifest that would resurrect data after pod death cannot merge. The
"RAM-only" claim is enforced at the gate, not documented and hoped for.

## layer 2: unit tests (every push)

`python -m pytest tests/test_submission_api.py` boots the real API in
process and checks the behaviours the threat model depends on:

- stored bytes are exactly the received bytes (no transformation)
- oversize and empty submissions are rejected before storage
- the per-IP token bucket rejects bursts
- the retention purge removes stale submissions and only stale ones
- **no access logs are produced** (the stdout/stderr capture is asserted
  empty - this is the "no IP addresses on disk" guarantee at the app layer)
- counters exist and never contain IP addresses

## layer 3: local smoke proof (no kubernetes)

`bash tests/local-smoke.sh` runs the full client -> server -> operator
round trip on localhost:

- `S1` server stored the submission
- `S2` plaintext marker absent from server storage (ciphertext at rest)
- `S3` operator offline decrypt round-trips the plaintext
- `S4` retention purge erases with no residue
- `S5` server stdout is silent about submissions

## layer 4: the cluster proof (CI, kind + calico)

`tests/kind-proof.sh` against a real cluster built in CI. Full assertion
list:

| id | claim proven |
|---|---|
| P1 | both workloads reach Ready |
| P2 | zero PVCs, zero StatefulSets in the namespace |
| P3 | `/dev/shm` inside the running api pod is tmpfs (`/proc/mounts`) |
| P4 | `/dev/shm` inside the tor pod is tmpfs |
| P5 | a v3 onion address is published (charset and length validated) |
| P6 | a pod outside the namespace cannot connect (default-deny) |
| P7 | a pod inside the namespace but not tor cannot connect (ingress allowlist) |
| P8 | the single allowed path tor -> api accepts a submission |
| P9 | the submission really landed in pod RAM (marker grep inside the pod) |
| P10 | the api root filesystem refuses writes (live `touch` attempt) |
| P11 | a sealed-box submission is stored with zero plaintext present |
| P12 | metrics are consistent with traffic and contain no IPs |
| P13 | after `delete pod --force --grace-period=0`, the fresh pod holds zero submissions |
| P14 | after restarting tor, the onion address is different (burner rotation) |

The most interesting one is P13 + P14 together: they demonstrate the two
halfs of the erase story - the data dies with the api pod, and the identity
dies with the tor pod. A seized cluster right after a burn has neither the
ciphertext nor the address it arrived on.

Reproduce outside CI: the quickstart in the README recreates the same kind
cluster; then `bash tests/kind-proof.sh`.

## layer 5: container scanning

trivy fails CI on HIGH/CRITICAL findings with upstream fixes for:

- the api image (python:3.12-alpine3.22, zero deps)
- the tor image (alpine 3.22, tor from the alpine repos, curl)
- the client dependency file (pynacl, pysocks - pinned)

## what is intentionally NOT asserted

- tor network bootstrap in CI (slow, flaky, and not a property of this
  codebase - the onion address is generated before any rendezvous)
- kernel memory reclaim timing after pod death (P13 asserts the observable
  outcome: a fresh pod sees an empty directory; the kernel's page
  reclamation is the mechanism)
- client-side anti-forensics on the whistleblower's machine (out of scope;
  the client does wipe its buffer, but endpoint security belongs to the
  source's threat model)
