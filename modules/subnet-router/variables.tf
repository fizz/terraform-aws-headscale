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
  description = "CIDR ranges to advertise via the subnet router"
  type        = list(string)
}

variable "advertise_tags" {
  description = "Headscale ACL tag applied to this subnet-router node (e.g. tag:infra)"
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

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
