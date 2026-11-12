# ghost-box threat model

## assets

1. **submission contents** - the leaked documents themselves. Highest value.
2. **source identity** - metadata that could identify who sent what: IPs,
   timings, sizes, fingerprints.
3. **source list** - the existence of a submission at all can be dangerous
   in the wrong jurisdiction.
4. **operator private key** - unseals everything if captured.
5. **current onion address** - knowledge of the live address allows
   blocking, probing and correlation.

## adversaries

- **A1: network observer / ISP** - can see the source's connection, runs
  passive correlation.
- **A2: platform seizer** - obtains the cloud account, the nodes, or the
  hardware. Has time, forensic tools and legal pressure.
- **A3: insider / compromised operator workstation** - the people running
  ghost-box are on the attack path too.
- **A4: active attacker on the cluster** - has a pod somewhere in the
  cluster (another tenant, a compromised workload) and wants to move
  laterally into ghost-box.
- **A5: supply chain attacker** - poisons a dependency, image or the
  pipeline.

## attack trees and controls

### T1: deanonymize a source (A1)

| path | control |
|---|---|
| sniff the source's connection | tor client-side; ghost-box never sees a real IP |
| correlate server-side logs | no access logs exist; HTTP logging disabled at the code level |
| fingerprint via response behaviour | responses are constant-shape JSON, no per-client state |
| long-term onion address correlation | addresses are burner keys in tmpfs, rotated on every pod restart |

Residual risk: tor network-level attacks (guard discovery) and traffic
correlation on a low-volume hidden service. Documented, not solved; see
"honest limits" in the README.

### T2: recover submissions after seizure (A2)

| path | control |
|---|---|
| image the node disk | submissions live in tmpfs; node disks hold only the OS and container images |
| read pod logs | there are none worth reading - counters only, no content, no IPs |
| restore from backup | no backups exist by policy (no PVCs; CI-enforced) |
| dump memory of the api pod | requires a live, running pod; this is exactly the "burn first" runbook step |
| force the cloud provider | out of scope for any software; the burn procedure is the answer and it takes seconds |

### T3: decrypt captured ciphertext (A1/A2)

| path | control |
|---|---|
| brute the sealed box | NaCl sealed box with X25519/Salsa20/Poly1305 - no known shortcut |
| find the private key on the server | it is never there; the API has no key material at all |
| compromise the operator's key storage | runbook: key lives offline, on an air-gapped machine; decrypt happens offline |

### T4: lateral movement into ghost-box (A4)

| path | control |
|---|---|
| reach the api from any other pod | calico default-deny + single-source ingress policy; proven by CI probes P6/P7 |
| pivot from tor pod | tor pod egress excludes RFC1918; it cannot route into private space |
| abuse node IMDS | IMDSv2 required, hop limit 1 - pods cannot query instance metadata |
| abuse the service account token | `automountServiceAccountToken: false` on every pod |

### T5: poison the supply chain (A5)

| path | control |
|---|---|
| malicious pip dependency | the API has zero dependencies; the client has two, pinned, and scanned by trivy |
| malicious base image | alpine 3.20 pinned, scanned by trivy, CI fails on HIGH/CRITICAL with fixes |
| malicious policy change | policies live next to the manifests; a weakening change is visible in review and in CI diffs |

### T6: break the erase guarantee (A3/A4)

| path | control |
|---|---|
| mount a persistent volume quietly | conftest rejects PVC/CSI/hostPath/disk-backed emptyDir before merge |
| write to the container rootfs | `readOnlyRootFilesystem: true`, proven live by CI probe P10 |
| exfiltrate to an external endpoint | api pod egress is denied except DNS; the api has no client to exfiltrate with |
| survive via StatefulSet identity | StatefulSets are banned by policy |

## residual risks, stated plainly

- **live node forensics.** If the adversary captures a node while a pod is
  running and before it is burned, memory forensics can pull tmpfs contents.
  The runbook's burn procedure (`kubectl -n ghost-box delete pod --all -f`)
  is the correct incident response and takes seconds.
- **operator workstation compromise.** The private key on an online machine
  is game over. The runbook confines it to an offline machine.
- **low-volume correlation.** A hidden service with three visitors a week is
  correlatable by a global adversary. Real deployments should consider
  padding traffic and running behind busier infrastructure.
- **AWS account compulsion.** The platform is unseizable in software terms;
  the account is not. Legal threat model is out of scope for this repository
  and belongs to the operating organization.
- **client-side compromise.** ghost-box says nothing about the source's own
  endpoint security. That is the source's threat model.

## what "proven" means here

Every control marked "proven by CI" in this document corresponds to an
assertion in `tests/kind-proof.sh` or a conftest rule in `policy/` that runs
on every push. If a future change silently breaks one of these guarantees -
a new volume, a new port, a log line with an IP - the pipeline fails before
the change lands. That is the whole point of the repository.
