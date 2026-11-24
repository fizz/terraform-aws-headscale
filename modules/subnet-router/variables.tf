variable "name_prefix" {
  description = "Prefix for all resource names (SG, IAM role, log group, etc.)"
  type        = string
  default     = "headscale"
}

variable "vpc_id" {
  description = "VPC ID for the subnet router instance"
  type        = string
}

variable "subnet_id" {
  description = "Private subnet ID (optional — auto-detected from VPC if not set)"
  type        = string
  default     = null
}

variable "headscale_server_url" {
  description = "URL of the Headscale coordination server (e.g. https://vpn.example.com)"
  type        = string
}

variable "advertised_routes" {
  description = "CIDR ranges to advertise via the subnet router. An empty list advertises nothing, for a router that only reaches ranges other routers advertise. A change replaces the instance"
  type        = list(string)
  default     = []
}

variable "advertise_tags" {
  description = "Headscale ACL tag of this subnet-router node (e.g. tag:infra). The pre-auth key in auth_key_ssm_path must carry this tag: the key applies it, and the router does not request it."
  type        = string
}

variable "hostname" {
  description = "Tailscale hostname for this subnet-router node"
  type        = string
  default     = "subnet-router"
}

variable "auth_key_ssm_path" {
  description = "SSM Parameter Store path containing the Headscale pre-auth key"
  type        = string
  default     = "/headscale/auth-key"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t4g.nano"
}

variable "aws_region" {
  description = "AWS region (used in userdata for SSM API calls)"
  type        = string
  default     = "us-east-1"
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days"
  type        = number
  default     = 365
}

variable "sg_description" {
  description = "Description for the security group"
  type        = string
  default     = "Headscale subnet router - outbound only"
}

variable "ami_id" {
  description = "EC2 AMI ID, Amazon Linux 2023 for arm64. Required: a new AMI replaces the instance, so the version changes only when this value does. The current one is at the SSM parameter /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be an AMI ID such as ami-0123456789abcdef0."
  }
}

variable "accept_routes" {
  description = "Accept the routes that other routers in the tailnet advertise, so hosts in the VPC can reach them. A change runs on the running instance"
  type        = bool
  default     = false
}

variable "masquerade_cidrs" {
  description = "Source CIDR ranges to rewrite to the router's tailnet address when their traffic leaves tailscale0, for a router that advertises no route. A change runs on the running instance"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.masquerade_cidrs : can(cidrnetmask(cidr))])
    error_message = "masquerade_cidrs must be IPv4 CIDR ranges such as 10.0.0.0/16."
  }
}

variable "clamp_mss_to_pmtu" {
  description = "Clamp the TCP MSS of forwarded connections through tailscale0 to its MTU, on the SYN going out and the SYN-ACK coming back. A change runs on the running instance"
  type        = bool
  default     = false
}

variable "root_volume_size" {
  description = "Root volume size in GiB. The Amazon Linux 2023 AMI has an 8 GiB root, the smallest size EC2 accepts for it. A larger value grows the volume in place; a smaller one replaces the instance"
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 8 && var.root_volume_size == floor(var.root_volume_size)
    error_message = "root_volume_size must be a whole number of GiB, 8 or more."
  }
}

variable "provision_schedule" {
  description = "How often the client gateway association runs again on the instance, to put back changes made by hand. Used only when accept_routes, masquerade_cidrs or clamp_mss_to_pmtu is set"
  type        = string
  default     = "rate(1 day)"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
