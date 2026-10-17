#!/bin/bash
# First boot only: mount the persistent volume. The SSM association
# "${name_prefix}-provision" does everything else, and runs again on a schedule and
# on every change, so a failed step can be run again without a new instance.
set -euo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

MOUNT=/var/lib/headscale/cache
DEVICE="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(printf '%s' "${cache_volume_id}" | tr -d '-')"

# Terraform attaches the volume after the instance starts, so it can appear minutes
# after this script starts. Wait for it in the loop.
for i in $(seq 1 60); do
  if [ -e "$DEVICE" ]; then
    break
  fi
  if [ -b /dev/xvdf ]; then
    DEVICE=/dev/xvdf
    break
  fi
  if [ "$i" = 60 ]; then
    echo "volume ${cache_volume_id} not attached after 5 minutes" >&2
    exit 1
  fi
  sleep 5
done

mkdir -p "$MOUNT"
if ! blkid "$DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 -F "$DEVICE"
fi
if ! grep -q " $MOUNT " /etc/fstab; then
  echo "$DEVICE $MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
fi
mountpoint -q "$MOUNT" || mount "$MOUNT"
echo "volume ${cache_volume_id} mounted at $MOUNT"
