package main

# pod hardening: non-root, no privilege escalation, read-only root
# filesystem, all capabilities dropped, seccomp, pinned resources.

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.securityContext.runAsNonRoot
  msg := sprintf("deployment %s must set runAsNonRoot", [input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.securityContext.seccompProfile.type
  msg := sprintf("deployment %s must set seccompProfile.type", [input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  not input.spec.template.spec.automountServiceAccountToken == false
  msg := sprintf("deployment %s must set automountServiceAccountToken: false", [input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.securityContext
  msg := sprintf("container %s in %s has no securityContext", [container.name, input.metadata.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.securityContext.allowPrivilegeEscalation == false
  msg := sprintf("container %s must set allowPrivilegeEscalation: false", [container.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.securityContext.readOnlyRootFilesystem
  msg := sprintf("container %s must set readOnlyRootFilesystem: true", [container.name])
}

has_all_drop(container) {
  container.securityContext.capabilities.drop[i] == "ALL"
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not has_all_drop(container)
  msg := sprintf("container %s must drop ALL capabilities", [container.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.memory
  msg := sprintf("container %s must set a memory limit", [container.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  not container.resources.limits.cpu
  msg := sprintf("container %s must set a cpu limit", [container.name])
}

deny[msg] {
  input.kind == "Deployment"
  container := input.spec.template.spec.containers[_]
  endswith(container.image, ":latest")
  msg := sprintf("container %s must pin a version tag, not latest", [container.name])
}
