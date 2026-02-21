variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
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

variable "headscale_domain" {
  description = "FQDN for the Headscale server (e.g. vpn.example.com)"
  type        = string
}

variable "oidc_issuer" {
  description = "OIDC issuer URL"
  type        = string
  default     = "https://accounts.google.com"
}

variable "oidc_client_id" {
  description = "OIDC client ID for Headscale authentication"
  type        = string
  sensitive   = true
}

variable "allowed_domains" {
  description = "Email domains allowed to authenticate via OIDC"
  type        = list(string)
}

variable "advertised_routes" {
  description = "CIDR ranges to advertise via the subnet router"
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
