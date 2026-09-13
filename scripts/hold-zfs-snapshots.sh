#!/bin/bash
# /root/scripts/hold-zfs-snapshots.sh

# Workaround for snapshot mounts. We need to hold them open while the docker container is active
# This is scheduled with crontab to run shortly before the restic container at 1:59 every day.

SNAPSHOT_DIRS=(
  "/mnt/Pool/App_Storage/Audiobookshelf/config/.zfs/snapshot"
  "/mnt/Pool/App_Storage/Audiobookshelf/metadata/.zfs/snapshot"
  "/mnt/Pool/App_Storage/Navidrome/data/.zfs/snapshot"
  "/mnt/Pool/App_Storage/Navidrome/music/.zfs/snapshot"
  "/mnt/Pool/App_Storage/immich/data/.zfs/snapshot"
  "/mnt/Pool/App_Storage/immich/immich_postgres16/.zfs/snapshot"
  "/mnt/Pool/App_Storage/syncthing/config/.zfs/snapshot"
)

HOLD_SECONDS=1200   # 20 minutes — bump this if backups run longer

FDS=()
base_fd=200
i=0
for dir in "${SNAPSHOT_DIRS[@]}"; do
    latest=$(ls -1 "$dir" 2>/dev/null | sort | tail -n 1)
    if [ -n "$latest" ]; then
        fd=$((base_fd + i))
        eval "exec $fd< \"$dir/$latest\""
        FDS+=("$fd")
        echo "[$(date)] Holding open: $dir/$latest (fd $fd)"
    else
        echo "[$(date)] WARNING: no snapshot found in $dir"
    fi
    i=$((i + 1))
done

sleep "$HOLD_SECONDS"

for fd in "${FDS[@]}"; do
    eval "exec $fd<&-"
done
echo "[$(date)] Released all held snapshot descriptors"
