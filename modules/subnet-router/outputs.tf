output "instance_id" {
  description = "EC2 instance ID of the subnet router"
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Private IP address of the subnet router"
  value       = aws_instance.this.private_ip
}

output "advertised_routes" {
  description = "Routes advertised by this subnet router"
  value       = var.advertised_routes
}

output "security_group_id" {
  description = "Security group ID attached to the subnet router"
  value       = aws_security_group.this.id
}

output "iam_role_arn" {
  description = "IAM role ARN for the subnet router instance"
  value       = aws_iam_role.this.arn
}
