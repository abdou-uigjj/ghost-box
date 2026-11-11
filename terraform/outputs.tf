output "cluster_name" {
  description = "eks cluster name"
  value       = aws_eks_cluster.ghost_box.name
}

output "cluster_endpoint" {
  description = "private control plane endpoint"
  value       = aws_eks_cluster.ghost_box.endpoint
}

output "cluster_ca" {
  description = "cluster certificate authority (base64)"
  value       = aws_eks_cluster.ghost_box.certificate_authority[0].data
  sensitive   = true
}

output "kms_key_arn" {
  description = "cmk encrypting node disks and cluster secrets"
  value       = aws_kms_key.storage.arn
}

output "vpc_id" {
  description = "ghost-box vpc id"
  value       = aws_vpc.ghost_box.id
}

output "private_subnet_ids" {
  description = "worker subnets"
  value       = aws_subnet.private[*].id
}

output "onion_address_hint" {
  description = "the onion address is NOT in terraform - it is generated at runtime by the tor pod. after deploying k8s/, run:"
  value       = "kubectl -n ghost-box exec deploy/tor -- cat /dev/shm/tor/hs/hostname"
}
