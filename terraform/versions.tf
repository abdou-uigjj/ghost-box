terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        project = "ghost-box"
        branch  = "perimeter"
      },
      var.tags
    )
  }
}

# kubernetes + helm talk to the private control plane through the
# admin network (VPN / peered bastion). aws cli supplies the token.
data "aws_eks_cluster" "this" {
  name = aws_eks_cluster.ghost_box.name

  depends_on = [aws_eks_cluster.ghost_box]
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}
