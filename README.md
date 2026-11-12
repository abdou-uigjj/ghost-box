# ghost-box

[![CI](https://github.com/abdou-uigjj/ghost-box/actions/workflows/ci.yml/badge.svg)](https://github.com/abdou-uigjj/ghost-box/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green)
![Python](https://img.shields.io/badge/python-3.12-blue)
![Kubernetes](https://img.shields.io/badge/kubernetes-EKS-orange)
![Tor](https://img.shields.io/badge/ingress-tor%20v3-purple)

An anonymous submission platform for whistleblowers and journalists, built on
EKS with one hard rule baked into every layer: **nothing a whistleblower sends
should ever be able to outlive the pod that received it.**

Traditional tip platforms run on servers with disks. Disks remember. Backups
remember longer. A seized machine keeps every submission that ever crossed it.
ghost-box removes the thing that gets seized: submissions live in tmpfs, the
network door is a tor onion service with no public endpoint, and the storage
the server holds is ciphertext it has no key to open.

## what problem does this solve

A journalist in a hostile jurisdiction needs sources to send documents without
being traced. The failures that get sources hurt are boring and predictable:

- a web server logs the source's IP for months
- a disk image outlives three hardware refreshes
- an exposed admin panel turns a tip platform into a tracking device
- a backup nobody remembers holds everything

ghost-box attacks each one directly:

| failure | ghost-box answer |
|---|---|
| server logs the source IP | zero access logs, tor hides the client, calico drops everything that is not tor |
| disk outlives the server | there is no disk write. submissions live in tmpfs; killing the pod reclaims the pages |
| exposed admin panel | no LoadBalancer, no NodePort, no Ingress. the only door is the onion service |
| forgotten backups | nothing to back up. persistent volumes are forbidden by CI policy |

The onion address is a **burner**: tor generates its keys in tmpfs, so every
restart publishes a brand new address. There is no long-lived hostname to
subpoena, correlate or block-list.

## the proof, not the promise

The CI pipeline runs a real kind cluster with real calico policies and makes
14 observable assertions. Highlights:

- `P2` - zero PVCs and zero StatefulSets exist in the namespace
- `P3` - `/dev/shm` inside the running pod is tmpfs (checked in `/proc/mounts`)
- `P6`/`P7` - probes from outside the namespace and from a pod inside it are
  both dropped by the default-deny policy
- `P8` - the single allowed path (tor pod -> api pod) accepts traffic
- `P11` - a sealed-box submission is stored with **no plaintext marker** in
  the storage the server can see
- `P13` - killing the api pod leaves a fresh pod holding **zero submissions**
- `P14` - killing the tor pod rotates the onion address

Run `bash tests/local-smoke.sh` for the no-kubernetes version of the same
story: boot the API, submit through the real client, prove the plaintext never
lands server-side, prove offline decryption, prove the purge.

## architecture

```
                        whistleblower laptop
                    encrypts with operator pubkey
                    (nacl sealed box, no key server-side)
                                |
                                | tor network
                                v
        +---------------------------------------------+
        |  private subnets, no igw, no nat             |
        |  +---------+        +--------------------+  |
        |  | tor pod | -----> | submission-api pod |  |
        |  | tmpfs   |  :80   | tmpfs /dev/shm     |  |
        |  | onion   |  only  | ciphertext in ram  |  |
        |  | keys    |  path  | stdlib, no deps    |  |
        |  +---------+        +--------------------+  |
        |        calico default-deny everything else  |
        +---------------------------------------------+
                                |
                     operator pulls + decrypts offline
                     (kubectl + ghost-box.key, never online)
```

- `terraform/` - private EKS: no internet gateway, no NAT. Workers pull
  images through VPC endpoints only. Control plane has public access
  disabled. Node disks encrypted with a rotating KMS key, IMDSv2 hop
  limit 1. Calico installed policy-only over the AWS VPC CNI.
- `k8s/` - hardened deployments: `readOnlyRootFilesystem`, all capabilities
  dropped, seccomp, non-root, no service account token, `Recreate` strategy.
- `app/` - the submission API. Python stdlib only, zero pip dependencies,
  so there is no supply chain to audit. 20 MiB cap, per-IP token bucket,
  in-memory counters, retention purge, silent logs.
- `tor/` - alpine + tor from the alpine repos (version gated by trivy in
  CI). SocksPort 0, ControlSocket 0, keys in tmpfs.
- `client/` - `secure_submit.py`: reads the file once, encrypts with the
  operator's public key (NaCl sealed box), wipes the local buffer, sends
  through tor SOCKS5.
- `tools/` - `keygen.py` + offline `decrypt.py` for the operator.
- `policy/` - conftest/Rego pack. A PR that adds a PVC, a hostPath, a
  writable rootfs or an exposed service fails CI before it merges.

## quickstart (kind lab, ~5 minutes)

```bash
kind create cluster --config tests/kind-config.yaml
docker build -t ghcr.io/abdou-uigjj/ghost-box-api:v1.0.0 app/
docker build -t ghcr.io/abdou-uigjj/ghost-box-tor:v1.0.0 tor/
kind load docker-image ghcr.io/abdou-uigjj/ghost-box-api:v1.0.0
kind load docker-image ghcr.io/abdou-uigjj/ghost-box-tor:v1.0.0

# calico (same steps the CI uses)
kubectl -n kube-system delete ds kindnet --ignore-not-found
curl -sSL https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml \
  | sed 's?192\.168\.0\.0/16?10.244.0.0/16?g' | kubectl apply -f -
kubectl -n kube-system wait --for=condition=ready pod -l k8s-app=calico-node --timeout=300s

kubectl apply -f k8s/
kubectl -n ghost-box exec deploy/tor -- cat /dev/shm/tor/hs/hostname
```

The last command prints the current onion address. Submit with:

```bash
python3 tools/keygen.py --out-dir keys/          # once, offline
python3 client/secure_submit.py \
  --onion http://<address>.onion/submit \
  --file evidence.zip \
  --pubkey-file keys/ghost-box.pub
```

For the production EKS path, see `terraform/` and `docs/runbook.md`.

## threat model in one paragraph

The adversary is a state-grade actor with network visibility, the ability to
serve deauth/subpoena requests, and patience. ghost-box assumes the cluster
itself may eventually be seized, and optimizes for what the seizure yields:
RAM ciphertext that vanishes with the pod, an onion address that died with
the previous restart, logs that were never written, and a server that cannot
decrypt anything. What it does **not** protect against is listed honestly in
[docs/threat-model.md](docs/threat-model.md) - live node forensics, a
compromised operator workstation, and traffic-correlation attacks on low
volume onion services all remain in scope for the defender to manage.

## docs

- [architecture](docs/architecture.md) - every component and why it exists
- [threat model](docs/threat-model.md) - adversaries, assets, attack trees
- [runbook](docs/runbook.md) - deploy, retrieve address, rotate, burn, IR
- [validation](docs/validation.md) - what each CI assertion proves

## honest limits

This is defense against seizure and surveillance of the *platform*. It is not
an anonymity guarantee for a source whose endpoint is compromised, and it is
not a replacement for the operational discipline of the people running it.
Low-volume onion services are correlatable; production deployments should run
behind existing traffic and rotate operators' decryption practice. Read the
threat model before trusting it with anything real.

## license

MIT
