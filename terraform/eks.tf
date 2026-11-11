# ----------------------------------------------------------------------------
# iam
# ----------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.cluster_name}-node"
  role = aws_iam_role.node.name
}

# ----------------------------------------------------------------------------
# kms: one cmk for node disks and one for cluster secret envelope encryption
# ----------------------------------------------------------------------------

resource "aws_kms_key" "storage" {
  description             = "ghost-box node disk + secret encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "storage" {
  name          = "alias/${var.cluster_name}-storage"
  target_key_id = aws_kms_key.storage.key_id
}

data "aws_iam_policy_document" "storage_key" {
  # account root keeps administrative control (break-glass recovery pattern)
  statement {
    sid       = "RootAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # the cluster may use the key only via the eks service
  statement {
    sid    = "EksEnvelope"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.cluster.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["eks.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key_policy" "storage" {
  key_id = aws_kms_key.storage.key_id
  policy = data.aws_iam_policy_document.storage_key.json
}

# ----------------------------------------------------------------------------
# control plane: private only. the api is reachable from the admin network
# through vpn or peering - never from the internet.
# ----------------------------------------------------------------------------

resource "aws_security_group" "admin" {
  name        = "${var.cluster_name}-admin"
  description = "who may talk to the private control plane"
  vpc_id      = aws_vpc.ghost_box.id

  ingress {
    description = "API from the vpc"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "API from the admin network"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    description = "return traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr, var.admin_cidr]
  }
}

resource "aws_eks_cluster" "ghost_box" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.30"

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    security_group_ids      = [aws_security_group.admin.id]
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.storage.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_kms_key_policy.storage,
  ]
}

# ----------------------------------------------------------------------------
# workers: private subnets, imdsv2 with hop limit 1, encrypted root disk
# ----------------------------------------------------------------------------

resource "aws_launch_template" "node" {
  name        = "${var.cluster_name}-node"
  description = "ghost-box worker - no public ip, encrypted disk, imdsv2"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.node_disk_size
      volume_type = "gp3"
      encrypted   = true
      kms_key_id  = aws_kms_key.storage.arn
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = { Name = "${var.cluster_name}-worker" }
  }
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.ghost_box.name
  node_group_name = "${var.cluster_name}-workers"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = var.node_min
    min_size     = var.node_min
    max_size     = var.node_max
  }

  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"
  disk_size      = null # disk comes from the launch template

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  labels = {
    "ghost-box.io/role" = "worker"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
    aws_iam_instance_profile.node,
  ]
}
