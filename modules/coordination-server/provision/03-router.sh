# Step 3: join this instance to its own tailnet as the subnet router for the VPC.

cat > /etc/sysctl.d/99-tailscale.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -q -p /etc/sysctl.d/99-tailscale.conf

# The node identity of the router stays on the persistent volume, so a new instance
# rejoins as the same node and keeps its approved routes.
if ! mountpoint -q "$VOLUME"; then
  echo "router: $VOLUME is not mounted, so the router does not join" >&2
  exit 1
fi
mkdir -p "$VOLUME/tailscale" /var/lib/tailscale
chmod 0700 "$VOLUME/tailscale"
if ! grep -q ' /var/lib/tailscale ' /etc/fstab; then
  echo "$VOLUME/tailscale /var/lib/tailscale none bind,nofail,x-systemd.requires-mounts-for=$VOLUME 0 0" >> /etc/fstab
fi
mountpoint -q /var/lib/tailscale || mount /var/lib/tailscale
mkdir -p /etc/systemd/system/tailscaled.service.d
cat > /etc/systemd/system/tailscaled.service.d/state-on-volume.conf << 'EOF'
[Unit]
RequiresMountsFor=/var/lib/tailscale
EOF
systemctl daemon-reload

if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL --retry 5 -o /etc/yum.repos.d/tailscale.repo \
    https://pkgs.tailscale.com/stable/amazon-linux/2023/tailscale.repo
  dnf_install tailscale
fi
systemctl enable --now tailscaled

# Resolve the Headscale domain to the private address, so the router does not go out
# through the EIP and back in.
TOKEN="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')"
PRIVATE_IP="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)"
sed -i '/ ${headscale_domain}$/d' /etc/hosts
echo "$PRIVATE_IP ${headscale_domain}" >> /etc/hosts

# Headscale gets its certificate from Let's Encrypt on first start.
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "https://${headscale_domain}/health"; then
    break
  fi
  if [ "$i" = 60 ]; then
    echo "router: https://${headscale_domain} not ready after 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

STATE="$(tailscale status --json 2>/dev/null | jq -r '.BackendState' || true)"
if [ "$STATE" != "Running" ]; then
  $HS users create default >/dev/null 2>&1 || true
  USER_ID="$($HS users list -o json | jq -r '.[] | select(.name == "default") | .id')"
  # A single-use key that expires in an hour. The node identity on the volume
  # makes a later join unnecessary.
  AUTHKEY="$($HS preauthkeys create --user "$USER_ID" --expiration 1h --tags "${advertise_tags}" -o json | jq -r '.key')"
  tailscale up \
    --login-server="https://${headscale_domain}" \
    --authkey="$AUTHKEY" \
    --hostname="${hostname}" \
    --advertise-routes="${advertised_routes}" \
    --snat-subnet-routes=true \
    --accept-dns=false
  echo "router: joined as ${hostname}"
else
  tailscale set --hostname="${hostname}" --advertise-routes="${advertised_routes}"
  echo "router: already joined"
fi

# Approve the routes. Find the node by its tailnet address, which does not change
# when Headscale renames a node.
TS_IP="$(tailscale ip -4)"
NODE_ID="$($HS nodes list -o json | jq -r --arg ip "$TS_IP" '.[] | select(.ip_addresses | index($ip)) | .id')"
if [ -z "$NODE_ID" ]; then
  echo "router: no Headscale node has address $TS_IP" >&2
  exit 1
fi
$HS nodes approve-routes -i "$NODE_ID" -r "${advertised_routes}"
echo "router: node $NODE_ID approved for ${advertised_routes}"
