#!/bin/bash
set -ex

# Log everything to CloudWatch
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting Headscale subnet router setup ==="

# Enable IP forwarding for subnet routing
cat >> /etc/sysctl.d/99-tailscale.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf

# Install dependencies
dnf install -y amazon-cloudwatch-agent jq tmux

# Auto-attach to a tmux session for interactive shells.
cat > /etc/profile.d/tmux-auto.sh << 'TMUXEOF'
if [ -t 0 ] && [ -t 1 ]; then
  if command -v tmux >/dev/null 2>&1; then
    if [ -z "$${TMUX:-}" ]; then
      exec tmux new-session -A -s ops
    fi
  fi
fi
TMUXEOF

# Get auth key from SSM
AUTHKEY=$(aws ssm get-parameter \
  --name "${auth_key_ssm_path}" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

# Install Tailscale client
curl -fsSL https://tailscale.com/install.sh | sh

# Connect Tailscale as subnet router to Headscale server
tailscale up \
  --login-server=${headscale_server_url} \
  --authkey="$AUTHKEY" \
  --advertise-routes=${advertised_routes} \
  --snat-subnet-routes=true \
  --advertise-tags=${advertise_tags} \
  --accept-dns=false \
  --hostname=${hostname}

# Configure CloudWatch agent for logs and basic metrics
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWEOF'
{
  "agent": {
    "run_as_user": "root"
  },
  "metrics": {
    "append_dimensions": {
      "AutoScalingGroupName": "$${aws:AutoScalingGroupName}",
      "InstanceId": "$${aws:InstanceId}",
      "InstanceType": "$${aws:InstanceType}"
    },
    "metrics_collected": {
      "disk": {
        "measurement": [
          "disk_used_percent"
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "/"
        ],
        "ignore_file_system_types": [
          "devtmpfs",
          "tmpfs",
          "overlay",
          "squashfs"
        ]
      },
      "mem": {
        "measurement": [
          "mem_used_percent"
        ],
        "metrics_collection_interval": 60
      },
      "swap": {
        "measurement": [
          "swap_used_percent"
        ],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "/${name_prefix}/subnet-router",
            "log_stream_name": "{instance_id}/user-data",
            "retention_in_days": ${log_retention_days}
          }
        ]
      }
    }
  }
}
CWEOF

# Start CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

echo "=== Subnet router setup complete ==="
echo "This router advertises: ${advertised_routes}"
echo "Connected to Headscale server: ${headscale_server_url}"
