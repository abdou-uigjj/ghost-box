# calico runs in policy-only mode on top of the aws vpc cni.
# the vpc cni keeps pod networking; calico enforces every
# NetworkPolicy in k8s/ - including the default-deny that makes
# the ghost-box namespace air-tight.

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
    }
  }
}

resource "helm_release" "calico" {
  name       = "calico"
  repository = "https://docs.tigera.io/calico/charts"
  chart      = "calico"
  version    = "3.28.2"
  namespace  = "tigera-operator"

  values = [
    yamlencode({
      installation = {
        kubernetesProvider = "EKS"
        cni = {
          type = "aws-vpc"
        }
        calicoNetwork = {
          bgp = "Disabled"
        }
      }
      defaultFelixConfiguration = {
        enabled = true
        felixConfiguration = {
          logSeverityScreen = "Warning"
        }
      }
    })
  ]

  depends_on = [aws_eks_node_group.workers]
}
