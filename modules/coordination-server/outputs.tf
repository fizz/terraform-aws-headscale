output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.this.id
}

output "elastic_ip" {
  description = "Elastic IP address"
  value       = aws_eip.this.public_ip
}

output "headscale_url" {
  description = "Headscale server URL"
  value       = "https://${var.domain}"
}

output "connect_command" {
  description = "Command for users to connect"
  value       = "tailscale up --login-server=https://${var.domain}"
}

output "ssm_connect" {
  description = "SSM command to connect to instance"
  value       = "aws ssm start-session --target ${aws_instance.this.id}"
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.this.id
}

output "log_group" {
  description = "CloudWatch log group for audit logs"
  value       = aws_cloudwatch_log_group.this.name
}
