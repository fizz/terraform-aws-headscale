# Step 1: ship the logs and the metrics. This step runs first, so that a failure in
# a later step still leaves its log in CloudWatch.

# The user data mounts the volume. Wait for it to finish on a new instance.
cloud-init status --wait >/dev/null 2>&1 || true

dnf_install amazon-cloudwatch-agent jq

mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json.new << 'CWEOF'
{
  "agent": {
    "run_as_user": "root"
  },
  "metrics": {
    "append_dimensions": {
      "InstanceId": "$${aws:InstanceId}",
      "InstanceType": "$${aws:InstanceType}"
    },
    "metrics_collected": {
      "disk": {
        "measurement": ["disk_used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["/", "/var/lib/headscale/cache"],
        "ignore_file_system_types": ["devtmpfs", "tmpfs", "overlay", "squashfs"]
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "swap": {
        "measurement": ["swap_used_percent"],
        "metrics_collection_interval": 60
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/headscale.log",
            "log_group_name": "${log_group}",
            "log_stream_name": "{instance_id}/headscale"
          },
          {
            "file_path": "/var/log/headscale-provision.log",
            "log_group_name": "${log_group}",
            "log_stream_name": "{instance_id}/provision"
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "${log_group}",
            "log_stream_name": "{instance_id}/user-data"
          }
        ]
      }
    }
  }
}
CWEOF

if install_if_changed /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json.new \
  /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  || ! systemctl is-active --quiet amazon-cloudwatch-agent; then
  /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config -m ec2 -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
fi

systemctl is-active amazon-cloudwatch-agent
echo "observability: done"
