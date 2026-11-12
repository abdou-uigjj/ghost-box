# ghost-box runbook

Operational procedures for running ghost-box on the private EKS cluster.
Read `docs/threat-model.md` first so the "why" behind each step is clear.

## 0. prerequisites

- kubectl configured against the private API endpoint (VPN or bastion)
- terraform 1.6+ for the substrate
- docker for image builds
- an offline machine for key material

## 1. deploy the substrate

```bash
cd terraform
cp example.tfvars.example terraform.tfvars   # edit values
terraform init
terraform apply
aws eks update-kubeconfig --name ghost-box --region eu-central-1
```

The apply ends with `onion_address_hint` reminding you that terraform does
not know the address - it does not exist yet.

## 2. build and ship images

The nodes have no internet, so images must live in a registry reachable
through the ECR VPC endpoints:

```bash
docker build -t <account>.dkr.ecr.<region>.amazonaws.com/ghost-box-api:v1.0.0 app/
docker build -t <account>.dkr.ecr.<region>.amazonaws.com/ghost-box-tor:v1.0.0 tor/
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
docker push <account>.dkr.ecr.<region>.amazonaws.com/ghost-box-api:v1.0.0
docker push <account>.dkr.ecr.<region>.amazonaws.com/ghost-box-tor:v1.0.0

kubectl -n ghost-box set image deploy/submission-api api=<account>.dkr.ecr.<region>.amazonaws.com/ghost-box-api:v1.0.0
kubectl -n ghost-box set image deploy/tor tor=<account>.dkr.ecr.<region>.amazonaws.com/ghost-box-tor:v1.0.0
```

## 3. generate keys (offline machine only)

```bash
python3 tools/keygen.py --out-dir keys/
```

- publish `keys/ghost-box.pub` through whatever out-of-band channel you use
  to announce the onion address (same discipline as SecureDrop: never the
  same channel as the submissions).
- `keys/ghost-box.key` stays on the offline machine. If it ever touches a
  networked host, treat every submission as compromised and rotate.

## 4. start the platform and read the address

```bash
kubectl apply -f k8s/
kubectl -n ghost-box rollout status deploy/submission-api
kubectl -n ghost-box rollout status deploy/tor
kubectl -n ghost-box exec deploy/tor -- cat /dev/shm/tor/hs/hostname
```

Wait for tor to publish (up to ~30s after the pod is Running). The address
ends in `.onion` and is 62 characters (56 + `.onion`).

## 5. collect a submission

```bash
POD=$(kubectl -n ghost-box get pod -l app=submission-api -o jsonpath='{.items[0].metadata.name}')
kubectl -n ghost-box exec "$POD" -- cat /dev/shm/submissions/<id>.bin > sealed.bin
gpg --list-packets sealed.bin   # optional sanity: it is opaque ciphertext
# on the offline machine:
python3 tools/decrypt.py --key-file keys/ghost-box.key --file sealed.bin --out evidence.out
```

## 6. rotate the onion address (burner rotation)

Rotating IS restarting:

```bash
kubectl -n ghost-box rollout restart deploy/tor
kubectl -n ghost-box rollout status deploy/tor
kubectl -n ghost-box exec deploy/tor -- cat /dev/shm/tor/hs/hostname
```

The old address stops resolving immediately. Publish the new one
out-of-band. Do this on any schedule you like (weekly is reasonable) and
**always** after any suspected exposure.

## 7. burn procedure (suspected compromise)

Seconds matter. In priority order:

```bash
# 1. erase all submission memory
kubectl -n ghost-box delete pod -l app=submission-api --force --grace-period=0

# 2. burn the onion identity
kubectl -n ghost-box delete pod -l app=tor --force --grace-period=0

# 3. verify the namespace is empty of storage
kubectl -n ghost-box get pvc   # must print "No resources"
```

Then investigate offline. The CI proof (P13, P14) demonstrates that steps 1
and 2 leave nothing behind - the same guarantees hold here.

## 8. incident response notes

- **leaked onion address** - rotate (section 6). The leaked address stops
  working; the new one was never in the leak.
- **suspicious traffic in the namespace** - check flow: only tor -> api:8080
  and DNS are legal. Anything else means policy was weakened; treat the
  deployment as hostile, burn, and audit the manifests against `policy/`.
- **operator key suspected compromised** - rotate keys, re-announce the new
  public key out-of-band. Old ciphertext is only readable with the old key;
  submissions received before rotation must be considered burned with it.
- **cluster control plane exposure** - the endpoint is private by default;
  if someone re-enabled public access, treat it as a full compromise: burn
  everything, tear the cluster down, redeploy from terraform.

## 9. monitoring without metadata

The API exposes five counters on `/metrics` (reachable only from the tor
pod). Scrape them from an in-cluster job if you want dashboards; never ship
them off-cluster with timestamps attached to anything else. The counters
die with the pod by design, and that is fine - the metrics exist to answer
"is it alive and accepting", not "who sent what".
