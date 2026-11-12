GHOST-BOX CHANGELOG
===================

v1.0.0 - 2026-09-26
-------------------
first release.

* private EKS terraform: no internet gateway, no nat, control plane with
  public access disabled, imdsv2 workers with encrypted disks
* calico policy-only install for zero-trust NetworkPolicy enforcement
* submission api (python stdlib only): tmpfs storage, 20 MiB cap,
  per-ip token bucket, silent logs, in-memory counters, retention purge
* tor v3 onion service with ephemeral keys (burner address per pod)
* sealed-box client encryption: the server never holds a decryption key
* operator tools: keygen + offline decrypt
* conftest policy pack: no PVCs, tmpfs-only, pod hardening, no exposed
  services
* ci: yamllint + shellcheck + pytest + conftest + local smoke proof +
  terraform gates + kind/calico cluster proof (14 assertions) + trivy
