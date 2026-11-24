#!/bin/bash
# Client gateway: hosts in this VPC reach ranges that other routers advertise, and
# this router advertises nothing back. Safe to run again: every run sets the state
# below and removes what an earlier run set.
set -euo pipefail

exec > >(tee -a /var/log/client-gateway.log) 2>&1

ACCEPT_ROUTES=${accept_routes}
MASQUERADE_CIDRS="${masquerade_cidrs}"
CLAMP_MSS=${clamp_mss}
RULES=/usr/local/sbin/client-gateway-rules
CONF=/etc/client-gateway.conf
UNIT=/etc/systemd/system/client-gateway.service

# The user data installs and joins Tailscale on first boot, so a run that starts
# early waits for it. A run that gives up fails, and the schedule runs it again.
for attempt in $(seq 1 90); do
  if command -v tailscale >/dev/null 2>&1 &&
    [ "$(tailscale status --json 2>/dev/null | jq -r '.BackendState' || true)" = Running ]; then
    break
  fi
  if [ "$attempt" = 90 ]; then
    echo "client-gateway: tailscale is not running after 15 minutes" >&2
    exit 1
  fi
  sleep 10
done

# tailscale set changes only the setting it names. Tailscale keeps the setting
# across a reboot.
tailscale set --accept-routes="$ACCEPT_ROUTES"

# Remove the rules of the previous run before the files change.
if [ -x "$RULES" ]; then
  "$RULES" stop
fi

if [ -z "$MASQUERADE_CIDRS" ] && [ "$CLAMP_MSS" != true ]; then
  systemctl disable --now client-gateway.service 2>/dev/null || true
  rm -f "$UNIT" "$RULES" "$CONF"
  systemctl daemon-reload
  echo "client-gateway: accept_routes=$ACCEPT_ROUTES, no firewall rules"
  exit 0
fi

if ! command -v iptables >/dev/null 2>&1; then
  for attempt in 1 2 3 4 5 6; do
    dnf install -y iptables-nft && break
    if [ "$attempt" = 6 ]; then
      exit 1
    fi
    sleep $((attempt * 10))
  done
fi

cat > "$CONF" << EOF
MASQUERADE_CIDRS="$MASQUERADE_CIDRS"
CLAMP_MSS=$CLAMP_MSS
EOF

cat > "$RULES" << 'EOF'
#!/bin/bash
# client-gateway-rules start|stop. Each rule is removed first, so start does not
# stack a rule twice.
set -eu
# shellcheck source=/dev/null
. /etc/client-gateway.conf
mode="$${1:?start or stop}"

rule() {
  local table="$1"
  shift
  while iptables -t "$table" -C "$@" 2>/dev/null; do
    iptables -t "$table" -D "$@"
  done
  if [ "$mode" = start ]; then
    iptables -t "$table" -A "$@"
  fi
}

for cidr in $MASQUERADE_CIDRS; do
  rule nat POSTROUTING -s "$cidr" -o tailscale0 -j MASQUERADE
done
# The -o rule clamps the SYN that leaves through tailscale0. The -i rule clamps the
# SYN-ACK that comes back through it: --clamp-mss-to-pmtu takes the smaller of the
# MTU of the outgoing route and the MTU of the route back to the sender, so the
# reply that leaves the VPC interface gets the MSS of tailscale0.
if [ "$CLAMP_MSS" = true ]; then
  rule mangle FORWARD -o tailscale0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  rule mangle FORWARD -i tailscale0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
fi
EOF
chmod 0755 "$RULES"

cat > "$UNIT" << 'EOF'
[Unit]
Description=Client gateway firewall rules
After=tailscaled.service
Wants=tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/client-gateway-rules start
ExecStop=/usr/local/sbin/client-gateway-rules stop

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable client-gateway.service
systemctl restart client-gateway.service
echo "client-gateway: accept_routes=$ACCEPT_ROUTES, masquerade=$MASQUERADE_CIDRS, clamp_mss=$CLAMP_MSS"
