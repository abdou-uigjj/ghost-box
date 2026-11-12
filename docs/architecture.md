# ghost-box architecture

## components

### 1. private EKS substrate (`terraform/`)

The cluster sits in a VPC with private subnets only. There is no internet
gateway and no NAT gateway, so worker nodes have exactly one way to reach the
outside world: the VPC endpoints list (`ecr.api`, `ecr.dkr`, `s3`, `sts`,
`ec2messages`, `ssmmessages`, `logs`, `monitoring`, `elasticloadbalancing`).
Anything the nodes talk to that is not in that list does not exist for them.

The control plane runs with `endpoint_public_access = false`. Administration
happens from a VPN or peered bastion network (`admin_cidr`), and the admin
security group is the only place that CIDR is honored. Cluster secrets get
envelope encryption with a rotating KMS key. Worker disks are EBS gp3 with
the same key, IMDSv2 is mandatory and the hop limit is 1 so pods cannot
request instance credentials.

Calico is installed in policy-only mode (`cni.type: aws-vpc`): the AWS VPC
CNI keeps handling pod IPs, Calico enforces every NetworkPolicy. This is the
documented EKS pattern and avoids fighting the VPC CNI.

### 2. the tor door (`k8s/30-tor.yaml`, `tor/`)

A single tor daemon with `SocksPort 0`. It publishes one v3 onion service
that forwards to the submission API service. The important property is where
the onion keys live: `DataDir` points into the container's own `/dev/shm`
tmpfs. Restart the pod and the keypair is gone; the next start generates a
new one. The address is a burner by construction.

There is deliberately no NodePort, no LoadBalancer and no Ingress anywhere in
the namespace - conftest policy `004-network-shape.rego` rejects them at CI
time. The tor network is the only ingress path into ghost-box.

### 3. the submission API (`app/submission_api.py`)

Roughly 250 lines of Python stdlib. No pip dependencies at all, which is a
security decision, not a laziness decision: a server that handles
irreplacable documents should have a dependency tree a reviewer can read in
one sitting.

Behaviour:

- `POST /submit` - reads at most 20 MiB, writes it under
  `/dev/shm/submissions/<random>.bin` (tmpfs, mode 0600), returns a receipt.
  There is no filename to guess and no index to dump.
- per-source-IP token bucket (default 30/min), in memory only.
- `GET /healthz`, `/readyz` - no information about the workload.
- `GET /metrics` - five integer counters. No IPs, no sizes per client, no
  timestamps of first/last event. The counters themselves die with the pod.
- retention janitor - a thread unlinks submissions older than
  `GB_RETENTION_HOURS` (default 24) even if the pod lives on.
- logging - the HTTP access log is disabled entirely. Pod logs are shipped
  to the node disk by kubelet, so the only safe log is no log.

### 4. zero-trust networking (`k8s/10-*.yaml`, `k8s/12-*.yaml`)

Three policies define the entire network:

1. `default-deny-all` - no ingress, no egress for any pod in the namespace.
2. `allow-dns` - the only egress add-on: DNS to kube-dns.
3. `allow-tor-to-api` - TCP 8080 into the api pod, source limited to pods
   with label `app: tor`. Plus `allow-tor-egress` letting the tor pod reach
   the internet (excluding RFC1918 so tor can never pivot inward).

Everything else is dropped on the floor. The CI proof demonstrates this with
live probes rather than trusting the YAML.

### 5. client + operator tools (`client/`, `tools/`)

The whistleblower's machine encrypts the file with the operator's X25519
public key using a NaCl sealed box before any connection is made. A sealed
box is ephemeral-key encryption: the sender does not need a key either, and
the ciphertext is unlinkable to other submissions from the same client.

The operator's private key never touches the cluster. Decryption happens
offline with `tools/decrypt.py`. A seized ghost-box server is a pile of
ciphertext by design.

### 6. policy pack (`policy/`)

conftest/Rego rules enforced in CI:

- no PVC, no CSI, no StatefulSets
- no hostPath, emptyDir must be `medium: Memory` with a `sizeLimit`
- containers: non-root, no privilege escalation, read-only rootfs, drop ALL
  caps, seccomp, memory+cpu limits, pinned image tags
- no LoadBalancer / NodePort / Ingress in the namespace

## data flow, end to end

1. source runs `secure_submit.py` locally with the file and the operator's
   public key.
2. the client seals the file (NaCl sealed box), wipes its plaintext buffer,
   and POSTs the ciphertext through tor SOCKS5 to the onion address.
3. tor rendezvous traffic lands on the tor pod; the tor pod forwards to the
   api pod over the single allowed path.
4. the api writes ciphertext bytes into tmpfs and returns a receipt.
5. the operator later pulls the file from the pod (`kubectl cat`) and
   decrypts offline.
6. the submission dies when the pod dies (or after the retention window).
7. restarting the tor pod publishes a fresh onion address; operators publish
   the new address out-of-band (the rotation is itself the burn procedure).

## design decisions and their costs

- **stdlib-only API** - tiny audit surface, but no TLS termination inside the
  namespace. This is fine: tor onion services provide the encryption layer,
  and adding TLS inside the namespace would change nothing about the threat
  model while adding a PKI to manage.
- **one replica, Recreate strategy** - scaling out would spread submissions
  across pods and complicate the "kill pod = data gone" story. Availability
  is traded for a clean erase story, which is the right trade for this
  threat model.
- **no persistent anywhere** - an operator who wants the submissions to
  survive must actively exfiltrate them, which is the correct incentive.
- **burner onion addresses** - sources must always fetch the current address
  out-of-band. A long-lived address would be more convenient and less safe;
  the runbook documents the rotation flow.
