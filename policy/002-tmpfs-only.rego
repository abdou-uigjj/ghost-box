package main

# the only writable medium allowed in ghost-box is tmpfs (emptyDir with
# medium: Memory). hostPath and writable disk-backed emptyDirs are banned.

deny[msg] {
  input.kind == "Pod"
  some i
  v := input.spec.volumes[i]
  v.hostPath
  msg := "hostPath volumes are forbidden in ghost-box"
}

deny[msg] {
  input.kind == "Deployment"
  some i
  v := input.spec.template.spec.volumes[i]
  v.hostPath
  msg := sprintf("deployment %s uses hostPath - forbidden", [input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  some i
  v := input.spec.template.spec.volumes[i]
  v.emptyDir
  not v.emptyDir.medium == "Memory"
  msg := sprintf("deployment %s uses a disk-backed emptyDir - set medium: Memory", [input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  some i
  v := input.spec.template.spec.volumes[i]
  v.emptyDir
  v.emptyDir.medium == "Memory"
  not v.emptyDir.sizeLimit
  msg := sprintf("deployment %s tmpfs volume needs a sizeLimit (unbounded RAM)", [input.metadata.name])
}
