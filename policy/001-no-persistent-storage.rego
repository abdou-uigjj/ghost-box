package main

# ghost-box forbids persistent volumes. every policy here gates the CI
# pipeline, so a manifest that tries to survive a pod restart is rejected
# before it can merge.

deny[msg] {
  input.kind == "PersistentVolumeClaim"
  msg := "ghost-box forbids PersistentVolumeClaims - submissions must live in tmpfs only"
}

deny[msg] {
  input.kind == "StatefulSet"
  msg := "ghost-box forbids StatefulSets - workloads must be stateless Deployments"
}

deny[msg] {
  input.kind == "Deployment"
  spec := input.spec.template.spec
  some i
  v := spec.volumes[i]
  v.persistentVolumeClaim
  msg := sprintf("deployment %s mounts a PVC - forbidden", [input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  spec := input.spec.template.spec
  some i
  v := spec.volumes[i]
  v.csi
  msg := sprintf("deployment %s mounts a CSI volume - forbidden (only tmpfs allowed)", [input.metadata.name])
}
