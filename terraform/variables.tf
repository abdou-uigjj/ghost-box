variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "ghost-box"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric and dashes."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "vpc_cidr" {
  description = "CIDR for the ghost-box VPC (private only, no internet gateway)"
  type        = string
  default     = "10.66.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "az_count" {
  description = "number of availability zones to span (2 lab, 3 production)"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "admin_cidr" {
  description = "CIDR of the admin network allowed to reach the private API endpoint"
  type        = string
  default     = "10.200.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be a valid IPv4 CIDR."
  }
}

variable "node_instance_type" {
  description = "worker instance type"
  type        = string
  default     = "m6i.large"
}

variable "node_min" {
  description = "minimum worker count"
  type        = number
  default     = 1
}

variable "node_max" {
  description = "maximum worker count"
  type        = number
  default     = 3
}

variable "node_disk_size" {
  description = "worker root disk size (encrypted with the CMK)"
  type        = number
  default     = 20
}

variable "tags" {
  description = "extra resource tags"
  type        = map(string)
  default     = {}
}
