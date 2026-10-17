# Shared by every provisioning step. Each step of the SSM document runs in its own
# shell, so each one starts with this file.
#
# No -x: the steps handle the OIDC client secret and a pre-auth key, and a trace
# would print both to the command output.
set -euo pipefail

exec > >(tee -a /var/log/headscale-provision.log) 2>&1

HS="/usr/local/bin/headscale --config /etc/headscale/config.yaml"
VOLUME=/var/lib/headscale/cache

# rpm holds an fcntl lock on /var/lib/rpm/.rpm.lock while it reads or changes the
# package database. Other processes take it too: at boot, the Inspector VM scanner
# lists the packages. dnf does not wait for that lock, and flock cannot see an fcntl
# lock, so wait with fuser. Another process can still take the lock between the
# check and the install, so dnf_install also retries. A failed dnf transaction
# changes nothing, so a retry is safe.
wait_for_rpm() {
  local i
  for i in $(seq 1 60); do
    if ! fuser /var/lib/rpm/.rpm.lock >/dev/null 2>&1; then
      return 0
    fi
    echo "rpm database in use, waiting ($i/60)"
    sleep 5
  done
  echo "rpm database still in use after 5 minutes, trying anyway"
}

dnf_install() {
  local i
  for i in 1 2 3 4 5 6; do
    wait_for_rpm
    if dnf install -y "$@"; then
      return 0
    fi
    echo "dnf install $* failed (attempt $i/6)"
    sleep $((i * 10))
  done
  return 1
}

# Replace a file only when its content changes. Returns 0 when it changed.
install_if_changed() {
  local new="$1" dest="$2"
  if [ -f "$dest" ] && cmp -s "$new" "$dest"; then
    rm -f "$new"
    return 1
  fi
  mv -f "$new" "$dest"
  return 0
}
