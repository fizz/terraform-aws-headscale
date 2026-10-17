variable "name_prefix" {
  description = "Prefix for all resource names (SG, IAM role, log group, etc.)"
  type        = string
  default     = "headscale"
}

variable "vpc_id" {
  description = "VPC ID for the Headscale instance"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID (optional — auto-detected from VPC if not set)"
  type        = string
  default     = null
}

variable "domain" {
  description = "FQDN for the Headscale server (e.g. vpn.example.com)"
  type        = string
}

variable "oidc_issuer" {
  description = "OIDC issuer URL (e.g. https://accounts.google.com)"
  type        = string
  default     = "https://accounts.google.com"
}

variable "oidc_client_id" {
  description = "OIDC client ID"
  type        = string
  sensitive   = true
}

variable "oidc_client_secret_ssm_path" {
  description = "SSM Parameter Store path containing the OIDC client secret"
  type        = string
  default     = "/headscale/oidc-client-secret"
}

variable "allowed_domains" {
  description = "Email domains allowed to authenticate via OIDC"
  type        = list(string)
}

variable "advertised_routes" {
  description = "CIDR ranges to advertise via the built-in subnet router"
  type        = list(string)
}

variable "advertise_tags" {
  description = "Headscale ACL tag applied to the subnet-router node (e.g. tag:infra)"
  type        = string
}

variable "hostname" {
  description = "Tailscale hostname for the built-in subnet router node"
  type        = string
  default     = "subnet-router"
}

variable "magic_dns_domain" {
  description = "MagicDNS base domain used inside the tailnet"
  type        = string
  default     = "vpn.internal"
}

variable "split_dns" {
  description = "DNS domains to resolve with specific nameservers inside the tailnet, for example { \"corp.local\" = [\"10.0.0.2\"] }. The ACL must allow the nameservers on port 53."
  type        = map(list(string))
  default     = {}
}

variable "acl_policy" {
  description = "Full Headscale ACL policy as a JSON string"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t4g.nano"
}

variable "ssh_key_name" {
  description = "EC2 key pair name (optional)"
  type        = string
  default     = null
}

variable "route53_zone_id" {
  description = "Route53 hosted zone ID for DNS record creation (optional — skipped if null)"
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days"
  type        = number
  default     = 365
}

variable "sg_description" {
  description = "Description for the security group"
  type        = string
  default     = "Headscale coordination server"
}

variable "ami_id" {
  description = "EC2 AMI ID, Amazon Linux 2023 for arm64. Required: a new AMI replaces the instance, so the version changes only when this value does. The current one is at the SSM parameter /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be an AMI ID such as ami-0123456789abcdef0."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "headscale_version" {
  description = "Headscale release to install, as its GitHub tag. A change installs it on the running instance"
  type        = string
  default     = "v0.29.5"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.headscale_version))
    error_message = "headscale_version must be a release tag such as v0.29.5."
  }
}

variable "provision_schedule" {
  description = "How often the provisioning association runs again on the instance, to put back changes made by hand"
  type        = string
  default     = "rate(1 day)"
}

variable "provision_wait_seconds" {
  description = "How long terraform apply waits for a provisioning run to succeed. 0 does not wait"
  type        = number
  default     = 1200
}
