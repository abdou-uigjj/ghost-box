locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # interface endpoints the workers need. the cluster has no nat gateway
  # and no internet gateway: this list IS the internet.
  interface_endpoints = [
    "com.amazonaws.${var.aws_region}.ecr.api",
    "com.amazonaws.${var.aws_region}.ecr.dkr",
    "com.amazonaws.${var.aws_region}.sts",
    "com.amazonaws.${var.aws_region}.ec2messages",
    "com.amazonaws.${var.aws_region}.ssmmessages",
    "com.amazonaws.${var.aws_region}.logs",
    "com.amazonaws.${var.aws_region}.monitoring",
    "com.amazonaws.${var.aws_region}.elasticloadbalancing",
  ]
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ----------------------------------------------------------------------------
# network: every subnet is private. no igw, no natgw, no public route.
# ----------------------------------------------------------------------------

resource "aws_vpc" "ghost_box" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.cluster_name}-vpc" }
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.ghost_box.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)

  tags = { Name = "${var.cluster_name}-private-${local.azs[count.index]}" }
}

# local traffic only - the tables hold a single route
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.ghost_box.id

  tags = { Name = "${var.cluster_name}-rt-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ----------------------------------------------------------------------------
# vpc endpoints: the only way nodes reach ECR, sts and friends
# ----------------------------------------------------------------------------

resource "aws_security_group" "endpoints" {
  name        = "${var.cluster_name}-endpoints"
  description = "TLS from inside the vpc to the interface endpoints"
  vpc_id      = aws_vpc.ghost_box.id

  ingress {
    description = "HTTPS from the vpc"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "return traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.ghost_box.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = { Name = "${var.cluster_name}-s3-gw" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = aws_vpc.ghost_box.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${var.cluster_name}-${each.value}" }
}
