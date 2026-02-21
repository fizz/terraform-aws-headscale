#!/bin/bash
set -ex

# Terraform-injected variables
HEADSCALE_DOMAIN="${headscale_domain}"
OIDC_ISSUER="${oidc_issuer}"
OIDC_CLIENT_ID="${oidc_client_id}"
ALLOWED_DOMAINS="${allowed_domains}"
ADVERTISED_ROUTES="${advertised_routes}"
AWS_REGION="${aws_region}"
CACHE_VOLUME_ID="${cache_volume_id}"
NAME_PREFIX="${name_prefix}"
MAGIC_DNS_DOMAIN="${magic_dns_domain}"
ADVERTISE_TAGS="${advertise_tags}"
HOSTNAME_TAG="${hostname}"
OIDC_CLIENT_SECRET_SSM_PATH="${oidc_client_secret_ssm_path}"

# Log everything to CloudWatch
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting Headscale setup ==="

# Enable IP forwarding for subnet routing
cat >> /etc/sysctl.d/99-tailscale.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf

# Install dependencies
dnf install -y amazon-cloudwatch-agent jq tmux

# Mount persistent cache volume (Let's Encrypt state)
CACHE_DEVICE=""
CACHE_VOLUME_ID_NO_DASH="$(printf '%s' "$CACHE_VOLUME_ID" | tr -d '-')"
if [ -n "$CACHE_VOLUME_ID_NO_DASH" ]; then
  if [ -e "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$CACHE_VOLUME_ID_NO_DASH" ]; then
    CACHE_DEVICE="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$CACHE_VOLUME_ID_NO_DASH"
  elif [ -b /dev/xvdf ]; then
    CACHE_DEVICE="/dev/xvdf"
  fi
fi

if [ -n "$CACHE_DEVICE" ]; then
  mkdir -p /var/lib/headscale/cache
  for i in {1..30}; do
    if [ -e "$CACHE_DEVICE" ]; then
      break
    fi
    sleep 1
  done
  if ! blkid "$CACHE_DEVICE" >/dev/null 2>&1; then
    mkfs.ext4 -F "$CACHE_DEVICE"
  fi
  if ! grep -q "$CACHE_DEVICE" /etc/fstab; then
    echo "$CACHE_DEVICE /var/lib/headscale/cache ext4 defaults,nofail 0 2" >> /etc/fstab
  fi
  mount /var/lib/headscale/cache || true
fi

# Install Headscale (systemd, no Docker)
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64) ARCH_CANDIDATES="arm64 aarch64" ;;
  x86_64) ARCH_CANDIDATES="amd64 x86_64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/juanfont/headscale/releases/latest || true)"
HEADSCALE_VERSION="$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name' 2>/dev/null || true)"
if [ -z "$HEADSCALE_VERSION" ] || [ "$HEADSCALE_VERSION" = "null" ]; then
  HEADSCALE_VERSION="v0.23.0"
  RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/juanfont/headscale/releases/tags/$HEADSCALE_VERSION || true)"
fi

ASSET_NAME=""
ASSET_URL=""
for arch in $ARCH_CANDIDATES; do
  ASSET_LINE="$(printf '%s' "$RELEASE_JSON" | jq -r --arg arch "$arch" '.assets[] | select(.name | test("linux_" + $arch + "(\\\\.tar\\\\.gz)?$")) | [.name, .browser_download_url] | @tsv' | head -n1)"
  if [ -n "$ASSET_LINE" ] && [ "$ASSET_LINE" != "null" ]; then
    ASSET_NAME="$(printf '%s' "$ASSET_LINE" | cut -f1)"
    ASSET_URL="$(printf '%s' "$ASSET_LINE" | cut -f2)"
  fi
  if [ -n "$ASSET_URL" ] && [ "$ASSET_URL" != "null" ]; then
    break
  fi
done

if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
  echo "Failed to find headscale release asset for $ARCH" >&2
  exit 1
fi

curl -fsSL -o /tmp/headscale.bin "$ASSET_URL"
case "$ASSET_NAME" in
  *.tar.gz)
    tar -xzf /tmp/headscale.bin -C /usr/local/bin headscale
    ;;
  *)
    install -m 0755 /tmp/headscale.bin /usr/local/bin/headscale
    ;;
esac

# Get OIDC client secret from SSM (optional - OIDC disabled if not available)
OIDC_CLIENT_SECRET=$(aws ssm get-parameter \
  --name "$OIDC_CLIENT_SECRET_SSM_PATH" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region "$AWS_REGION" 2>/dev/null || echo "")

# Create Headscale user and directories
useradd --system --home /var/lib/headscale --shell /sbin/nologin headscale || true
mkdir -p /etc/headscale /var/lib/headscale /var/lib/headscale/cache

# Auto-attach for ssm-user without needing to taint/recreate.
cat > /etc/profile.d/tmux-ssm-user.sh << 'TMUXEOF'
if [ -t 0 ] && [ -t 1 ]; then
  if [ "$(id -un)" = "ssm-user" ] && command -v tmux >/dev/null 2>&1; then
    if [ -z "$${TMUX:-}" ]; then
      exec tmux new-session -A -s ops
    fi
  fi
fi
TMUXEOF

# Create Headscale config
cat > /etc/headscale/config.yaml << EOF
server_url: https://$HEADSCALE_DOMAIN
listen_addr: 0.0.0.0:443
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false

private_key_path: /var/lib/headscale/private.key
noise:
  private_key_path: /var/lib/headscale/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48

derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default

disable_check_updates: true
ephemeral_node_inactivity_timeout: 30m

database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite

dns:
  magic_dns: true
  base_domain: $MAGIC_DNS_DOMAIN
  nameservers:
    global:
      - 1.1.1.1
      - 8.8.8.8

log:
  level: info
  format: json

oidc:
  only_start_if_oidc_is_available: false
  issuer: $OIDC_ISSUER
  client_id: $OIDC_CLIENT_ID
  client_secret: $OIDC_CLIENT_SECRET
  scope:
    - openid
    - profile
    - email
  allowed_domains: []

tls_letsencrypt_hostname: $HEADSCALE_DOMAIN
tls_letsencrypt_cache_dir: /var/lib/headscale/cache
tls_letsencrypt_challenge_type: HTTP-01
tls_letsencrypt_listen: ":80"

policy:
  mode: file
  path: /etc/headscale/acl.json
EOF

# Write ACL policy (caller provides full JSON via Terraform variable)
cat > /etc/headscale/acl.json << 'ACLEOF'
${acl_policy}
ACLEOF

# Set ownership for Headscale files
chown -R headscale:headscale /etc/headscale /var/lib/headscale
touch /var/log/headscale.log
chown headscale:headscale /var/log/headscale.log

# Run Headscale with systemd
cat > /etc/systemd/system/headscale.service << 'HSEOF'
[Unit]
Description=Headscale
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=headscale
Group=headscale
ExecStart=/usr/local/bin/headscale serve --config /etc/headscale/config.yaml
Restart=on-failure
RestartSec=5s
RuntimeDirectory=headscale
RuntimeDirectoryMode=0755
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=1048576
WorkingDirectory=/var/lib/headscale
StandardOutput=append:/var/log/headscale.log
StandardError=append:/var/log/headscale.log

[Install]
WantedBy=multi-user.target
HSEOF

systemctl daemon-reload
systemctl enable --now headscale

# Wait for Headscale to initialize with retries
echo "Waiting for Headscale to start..."
for i in {1..60}; do
  if /usr/local/bin/headscale --config /etc/headscale/config.yaml users list >/dev/null 2>&1; then
    echo "Headscale is ready"
    break
  fi
  if [[ $((i % 10)) -eq 0 ]]; then
    echo "Still waiting for Headscale... (attempt $i/60)"
  fi
  sleep 1
done

# Install Tailscale client for subnet routing
curl -fsSL https://tailscale.com/install.sh | sh

# Create pre-auth key for subnet router (reusable, 1 year expiry)
echo "Creating pre-auth key for subnet router..."
/usr/local/bin/headscale --config /etc/headscale/config.yaml users create default 2>/dev/null || true
sleep 2
USER_ID=$(/usr/local/bin/headscale --config /etc/headscale/config.yaml users list -o json | jq -r '.[] | select(.name=="default" or .username=="default") | .id')
if [ -z "$USER_ID" ]; then
  echo "ERROR: Could not find default user"
  exit 1
fi
echo "Found user ID: $USER_ID"

# Create auth key
AUTHKEY=$(/usr/local/bin/headscale --config /etc/headscale/config.yaml preauthkeys create --user "$USER_ID" --reusable --expiration 8760h --tags "$ADVERTISE_TAGS" -o json | jq -r '.key')
if [ -z "$AUTHKEY" ] || [ $${#AUTHKEY} -lt 10 ]; then
  echo "ERROR: Failed to create valid auth key"
  exit 1
fi
echo "Auth key created successfully"

# Avoid EIP hairpin by resolving the headscale domain locally.
IMDS_TOKEN="$(curl -fsSL -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' || true)"
PRIVATE_IP=""
if [ -n "$IMDS_TOKEN" ]; then
  PRIVATE_IP="$(curl -fsSL -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4 || true)"
fi
if [ -z "$PRIVATE_IP" ]; then
  PRIVATE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
fi
if [ -n "$PRIVATE_IP" ] && ! grep -q " $HEADSCALE_DOMAIN" /etc/hosts; then
  echo "$PRIVATE_IP $HEADSCALE_DOMAIN" >> /etc/hosts
fi

# Wait for headscale to be ready (first metrics, then HTTPS with valid cert)
echo "Waiting for headscale metrics..."
for i in {1..30}; do
  if curl -fsSL -o /dev/null "http://127.0.0.1:9090/metrics" 2>/dev/null; then
    echo "Headscale metrics ready"
    break
  fi
  echo "Waiting for headscale metrics... ($i/30)"
  sleep 2
done

# Wait for Let's Encrypt cert to be issued (HTTP-01 challenge)
echo "Waiting for Let's Encrypt certificate..."
for i in {1..60}; do
  if curl -fsSL -o /dev/null "https://$HEADSCALE_DOMAIN/" 2>/dev/null; then
    echo "HTTPS is ready"
    break
  fi
  echo "Waiting for ACME cert... ($i/60)"
  sleep 5
done

# Connect Tailscale as subnet router with tag for auto-approval (with retry)
echo "Connecting tailscale..."
for i in {1..5}; do
  if tailscale up \
    --login-server=https://"$HEADSCALE_DOMAIN" \
    --authkey="$AUTHKEY" \
    --advertise-routes="$ADVERTISED_ROUTES" \
    --snat-subnet-routes=true \
    --advertise-tags="$ADVERTISE_TAGS" \
    --accept-dns=false \
    --hostname="$HOSTNAME_TAG"; then
    echo "Tailscale connected successfully"
    break
  fi
  echo "Tailscale up failed, retrying... ($i/5)"
  sleep 5
done

# Enable the routes (auto-approve - initial setup only)
sleep 5
# Get the node ID for the subnet router we just registered
NODE_ID=$(/usr/local/bin/headscale --config /etc/headscale/config.yaml nodes list -o json | jq -r --arg hn "$HOSTNAME_TAG" '.[] | select(.given_name==$hn) | .id')
if [ -n "$NODE_ID" ]; then
  /usr/local/bin/headscale --config /etc/headscale/config.yaml nodes approve-routes -i "$NODE_ID" -r "$ADVERTISED_ROUTES" || true
fi

# Configure CloudWatch agent for audit logs and basic metrics
LOG_GROUP_NAME="/$NAME_PREFIX/audit-logs"
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWEOF
{
  "agent": {
    "run_as_user": "root"
  },
  "metrics": {
    "append_dimensions": {
      "AutoScalingGroupName": "\$${aws:AutoScalingGroupName}",
      "InstanceId": "\$${aws:InstanceId}",
      "InstanceType": "\$${aws:InstanceType}"
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
            "file_path": "/var/log/headscale.log",
            "log_group_name": "$LOG_GROUP_NAME",
            "log_stream_name": "{instance_id}/headscale",
            "retention_in_days": ${log_retention_days}
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "$LOG_GROUP_NAME",
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

echo "=== Headscale setup complete ==="
echo "Users can connect with: tailscale up --login-server=https://$HEADSCALE_DOMAIN"
