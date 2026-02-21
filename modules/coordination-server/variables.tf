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

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
