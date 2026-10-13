variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

# ---------- cross-account IAM roles ----------

variable "dev_role_arn" {
  description = "IAM role ARN to assume in the dev account (coordination server)"
  type        = string
}

variable "prod_role_arn" {
  description = "IAM role ARN to assume in the prod account (subnet router)"
  type        = string
}

# ---------- VPCs ----------

variable "dev_vpc_id" {
  description = "VPC ID in the dev account for the coordination server"
  type        = string
}

variable "prod_vpc_id" {
  description = "VPC ID in the prod account for the subnet router"
  type        = string
}

# ---------- coordination server ----------

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

# ---------- route advertisement ----------

variable "dev_advertised_routes" {
  description = "CIDR ranges to advertise from the dev account subnet router"
  type        = list(string)
}

variable "prod_advertised_routes" {
  description = "CIDR ranges to advertise from the prod account subnet router"
  type        = list(string)
}

variable "dev_advertise_tags" {
  description = "Headscale ACL tag for the dev subnet-router node (e.g. tag:dev)"
  type        = string
}

variable "prod_advertise_tags" {
  description = "Headscale ACL tag for the prod subnet-router node (e.g. tag:prod)"
  type        = string
}

# ---------- prod subnet router ----------

variable "prod_hostname" {
  description = "Tailscale hostname for the prod subnet-router node"
  type        = string
  default     = "prod-subnet-router"
}

variable "ami_id" {
  description = "Amazon Linux 2023 arm64 AMI ID. aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64 --query Parameter.Value --output text"
  type        = string
}
