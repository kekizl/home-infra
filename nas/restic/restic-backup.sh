#!/bin/sh
set -e

# ------------------------------------------------------------------
# Clean up password file (strip whitespace)
# ------------------------------------------------------------------
CLEAN_PW="/tmp/restic-password-clean"
tr -d '[:space:]' < "$RESTIC_PASSWORD_FILE" > "$CLEAN_PW"
export RESTIC_PASSWORD_FILE="$CLEAN_PW"

# ------------------------------------------------------------------
# Discord webhook
# ------------------------------------------------------------------
DISCORD_WEBHOOK=""
if [ -f "$DISCORD_WEBHOOK_FILE" ]; then
    DISCORD_WEBHOOK=$(tr -d '[:space:]' < "$DISCORD_WEBHOOK_FILE")
fi

notify_discord() {
    if [ -n "$DISCORD_WEBHOOK" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
             -d "{\"content\": \"$1\"}" "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
    fi
}

# ------------------------------------------------------------------
# Configuration
# Each entry maps to a bind-mounted .zfs/snapshot directory inside
# the container at /snapshots/<name>/
# The script picks the latest snapshot subdirectory automatically.
# ------------------------------------------------------------------
DATASETS="
abs-config
abs-metadata
navidrome-data
immich-data
immich-postgres
syncthing-config
"

RETENTION="--keep-daily 7 --keep-weekly 4 --keep-monthly 3"
TAG="nas"

# ------------------------------------------------------------------
# Helper: get latest snapshot dir inside a mounted snapshot folder
# TrueNAS names snapshots with timestamps so alphabetical sort works
# ------------------------------------------------------------------
get_latest_snapshot() {
    ls -1 "$1" 2>/dev/null | sort | tail -n 1
}

# ------------------------------------------------------------------
# Main backup loop
# ------------------------------------------------------------------
echo "[$(date)] Starting ZFS snapshot backup to $RESTIC_REPOSITORY"

OVERALL_OK=1
FAILED_LIST=""
BACKED_UP_LIST=""

for dataset in $DATASETS; do
    # Skip blank lines from the heredoc-style variable
    [ -z "$dataset" ] && continue

    SNAP_PARENT="/snapshots/${dataset}"

    # Safety check — mount point exists
    if [ ! -d "$SNAP_PARENT" ]; then
        echo "[$(date)] ERROR: Mount point $SNAP_PARENT not found — is the volume defined in compose?"
        FAILED_LIST="${FAILED_LIST} ${dataset}(no-mount)"
        OVERALL_OK=0
        continue
    fi

    LATEST=$(get_latest_snapshot "$SNAP_PARENT")

    if [ -z "$LATEST" ]; then
        echo "[$(date)] WARNING: No ZFS snapshots found under $SNAP_PARENT — skipping"
        echo "         Make sure TrueNAS periodic snapshot tasks are configured for this dataset."
        FAILED_LIST="${FAILED_LIST} ${dataset}(no-snapshot)"
        OVERALL_OK=0
        continue
    fi

    SNAP_PATH="${SNAP_PARENT}/${LATEST}"
    echo "[$(date)] Backing up [${dataset}] from ZFS snapshot: ${LATEST}"

    if restic backup "$SNAP_PATH" \
        --tag "$TAG" \
        --tag "$dataset" \
        --host "truenas"; then
        echo "[$(date)] ✓ ${dataset} backup succeeded"
        BACKED_UP_LIST="${BACKED_UP_LIST} ${dataset}"
    else
        echo "[$(date)] ✗ ${dataset} backup FAILED"
        FAILED_LIST="${FAILED_LIST} ${dataset}(backup-failed)"
        OVERALL_OK=0
    fi
done

# ------------------------------------------------------------------
# Forget / prune — runs even on partial failure so successful
# datasets still get pruned; failure is logged as a warning
# ------------------------------------------------------------------
echo "[$(date)] Running forget/prune for tag: $TAG"
if restic forget $RETENTION --prune --tag "$TAG" --host "truenas"; then
    echo "[$(date)] Prune successful"
else
    echo "[$(date)] WARNING: Prune failed"
fi

# ------------------------------------------------------------------
# Discord notification
# ------------------------------------------------------------------
TIMESTAMP=$(date -u +'%Y-%m-%d %H:%M UTC')

if [ "$OVERALL_OK" -eq 1 ]; then
    notify_discord "✅ **NAS restic backup succeeded** on \`truenas\` at ${TIMESTAMP}\nDatasets:${BACKED_UP_LIST}"
else
    if [ -n "$BACKED_UP_LIST" ]; then
        # Partial failure
        notify_discord "⚠️ **NAS restic backup partially failed** on \`truenas\` at ${TIMESTAMP}\n✓ OK:${BACKED_UP_LIST}\n✗ Failed:${FAILED_LIST}"
    else
        # Total failure
        notify_discord "❌ **NAS restic backup FAILED** on \`truenas\` at ${TIMESTAMP}\n✗ Failed:${FAILED_LIST}"
    fi
fi

# ------------------------------------------------------------------
# Exit code — doco-cd reads this
# ------------------------------------------------------------------
if [ "$OVERALL_OK" -eq 1 ]; then
    exit 0
else
    exit 1
fi
