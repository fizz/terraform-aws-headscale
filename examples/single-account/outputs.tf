output "headscale_url" {
  description = "Headscale server URL"
  value       = module.headscale.headscale_url
}

output "elastic_ip" {
  description = "Elastic IP address"
  value       = module.headscale.elastic_ip
}

output "connect_command" {
  description = "Command for users to connect"
  value       = module.headscale.connect_command
}

output "ssm_connect" {
  description = "SSM command to connect to instance"
  value       = module.headscale.ssm_connect
}
