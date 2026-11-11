package main

# network shape: ghost-box services are cluster-internal only.
# no load balancer, no node port - the single door is the tor network.

deny[msg] {
  input.kind == "Service"
  input.metadata.namespace == "ghost-box"
  lower(input.spec.type) == "loadbalancer"
  msg := "LoadBalancer services are forbidden in ghost-box (tor is the only ingress)"
}

deny[msg] {
  input.kind == "Service"
  input.metadata.namespace == "ghost-box"
  lower(input.spec.type) == "nodeport"
  msg := "NodePort services are forbidden in ghost-box (tor is the only ingress)"
}

deny[msg] {
  input.kind == "Ingress"
  input.metadata.namespace == "ghost-box"
  msg := "Ingress resources are forbidden in ghost-box (tor is the only ingress)"
}
