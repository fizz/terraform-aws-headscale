# Step 2: install and configure Headscale. Each run compares the binary, the config,
# the ACL policy and the unit with what Terraform asks for, and restarts Headscale
# only when one of them changed.

# The database and the noise key stay on the persistent volume, so a new instance
# starts with the nodes and the server identity of the old one. Without the volume,
# Headscale would start with an empty database and a new key, and every node would
# have to join again. Stop instead.
if ! mountpoint -q "$VOLUME"; then
  echo "headscale: $VOLUME is not mounted, so Headscale does not start" >&2
  exit 1
fi
STATE_DIR="$VOLUME/state"

id headscale >/dev/null 2>&1 || useradd --system --home /var/lib/headscale --shell /sbin/nologin headscale
mkdir -p /etc/headscale /var/lib/headscale "$VOLUME" "$STATE_DIR"
chown headscale:headscale /var/lib/headscale "$VOLUME"
chown -R headscale:headscale "$STATE_DIR"
# The Let's Encrypt cache is at the top of the volume.
find "$VOLUME" -maxdepth 1 -type f -exec chown headscale:headscale {} +

CHANGED=0

# Binary: the version is pinned, so every instance runs the same Headscale.
WANT="${headscale_version}"
HAVE="$(/usr/local/bin/headscale version 2>/dev/null | awk '/^headscale version/ {print $3}' || true)"
if [ "$HAVE" != "$WANT" ]; then
  case "$(uname -m)" in
    aarch64) ARCH=arm64 ;;
    x86_64) ARCH=amd64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  curl -fsSL --retry 5 -o /usr/local/bin/headscale.new \
    "https://github.com/juanfont/headscale/releases/download/$WANT/headscale_$${WANT#v}_linux_$ARCH"
  chmod 0755 /usr/local/bin/headscale.new
  mv -f /usr/local/bin/headscale.new /usr/local/bin/headscale
  echo "headscale: installed $WANT (was $${HAVE:-none})"
  CHANGED=1
fi

# OIDC client secret. Without it, OIDC is off.
OIDC_CLIENT_SECRET="$(aws ssm get-parameter \
  --name "${oidc_client_secret_ssm_path}" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region "${aws_region}" 2>/dev/null || true)"

umask 027
cat > /etc/headscale/config.yaml.new << EOF
server_url: https://${headscale_domain}
listen_addr: 0.0.0.0:443
metrics_listen_addr: 127.0.0.1:9090
grpc_listen_addr: 127.0.0.1:50443
grpc_allow_insecure: false

private_key_path: $STATE_DIR/private.key
noise:
  private_key_path: $STATE_DIR/noise_private.key

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
    path: $STATE_DIR/db.sqlite

dns:
  magic_dns: true
  base_domain: ${magic_dns_domain}
  nameservers:
    global:
      - 1.1.1.1
      - 8.8.8.8
    split: ${split_dns}

log:
  level: info
  format: json

oidc:
  only_start_if_oidc_is_available: false
  issuer: ${oidc_issuer}
  client_id: ${oidc_client_id}
  client_secret: $OIDC_CLIENT_SECRET
  scope:
    - openid
    - profile
    - email
  allowed_domains: []

tls_letsencrypt_hostname: ${headscale_domain}
tls_letsencrypt_cache_dir: $VOLUME
tls_letsencrypt_challenge_type: HTTP-01
tls_letsencrypt_listen: ":80"

policy:
  mode: file
  path: /etc/headscale/acl.json
EOF
install_if_changed /etc/headscale/config.yaml.new /etc/headscale/config.yaml && CHANGED=1

cat > /etc/headscale/acl.json.new << 'ACLEOF'
${acl_policy}
ACLEOF
install_if_changed /etc/headscale/acl.json.new /etc/headscale/acl.json && CHANGED=1

chown root:headscale /etc/headscale /etc/headscale/config.yaml /etc/headscale/acl.json
chmod 0750 /etc/headscale
chmod 0640 /etc/headscale/config.yaml /etc/headscale/acl.json
umask 022

touch /var/log/headscale.log
chown headscale:headscale /var/log/headscale.log

cat > /etc/systemd/system/headscale.service.new << 'HSEOF'
[Unit]
Description=Headscale
After=network-online.target
Wants=network-online.target
RequiresMountsFor=/var/lib/headscale/cache

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
if install_if_changed /etc/systemd/system/headscale.service.new /etc/systemd/system/headscale.service; then
  systemctl daemon-reload
  CHANGED=1
fi

systemctl enable headscale
if [ "$CHANGED" = 1 ] || ! systemctl is-active --quiet headscale; then
  echo "headscale: restarting (changed=$CHANGED)"
  systemctl restart headscale
fi

for i in $(seq 1 60); do
  if $HS users list >/dev/null 2>&1; then
    echo "headscale: ready, $($HS version | awk '/^headscale version/ {print $3}')"
    exit 0
  fi
  sleep 2
done
echo "headscale: not ready after 2 minutes" >&2
exit 1
