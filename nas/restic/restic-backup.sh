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
# Helper: get latest snapshot dir
# ------------------------------------------------------------------
get_latest_snapshot() {
    ls -1 "$1" 2>/dev/null | sort | tail -n 1
}

# ------------------------------------------------------------------
# Build a single backup list from all ZFS snapshots
# ------------------------------------------------------------------
BACKUP_PATHS=""       # will hold all snapshot paths
MISSING_DATASETS=""   # collects datasets we couldn't find (for warning)
FOUND_COUNT=0

echo "[$(date)] Scanning ZFS snapshots..."

for dataset in $DATASETS; do
    [ -z "$dataset" ] && continue

    SNAP_PARENT="/snapshots/${dataset}"

    if [ ! -d "$SNAP_PARENT" ]; then
        echo "[$(date)] WARNING: Mount point $SNAP_PARENT missing — skipping ${dataset}"
        MISSING_DATASETS="${MISSING_DATASETS} ${dataset}"
        continue
    fi

    LATEST=$(get_latest_snapshot "$SNAP_PARENT")
    if [ -z "$LATEST" ]; then
        echo "[$(date)] WARNING: No ZFS snapshot found under $SNAP_PARENT — skipping ${dataset}"
        MISSING_DATASETS="${MISSING_DATASETS} ${dataset}"
        continue
    fi

    SNAP_PATH="${SNAP_PARENT}/${LATEST}"
    echo "[$(date)] Adding: [${dataset}] ← ${LATEST}"
    BACKUP_PATHS="$BACKUP_PATHS $SNAP_PATH"
    FOUND_COUNT=$((FOUND_COUNT + 1))
done

# ------------------------------------------------------------------
# Safety check — at least one dataset must be present
# ------------------------------------------------------------------
if [ "$FOUND_COUNT" -eq 0 ]; then
    echo "[$(date)] FATAL: No ZFS snapshots found for any dataset"
    notify_discord "❌ **NAS restic backup FAILED** on \`truenas\` at $(date -u +'%Y-%m-%d %H:%M UTC') — no snapshots found"
    exit 1
fi

# ------------------------------------------------------------------
# Single backup run — protects everything in one snapshot
# ------------------------------------------------------------------
echo "[$(date)] Starting ZFS snapshot backup to $RESTIC_REPOSITORY"
echo "[$(date)] Paths: $BACKUP_PATHS"

BACKUP_OK=0
if restic backup $BACKUP_PATHS --tag "$TAG" --host "truenas"; then
    echo "[$(date)] ✓ Backup succeeded (${FOUND_COUNT} datasets)"
    BACKUP_OK=1
else
    echo "[$(date)] ✗ Backup FAILED"
fi

# ------------------------------------------------------------------
# Forget / prune
# ------------------------------------------------------------------
if [ "$BACKUP_OK" -eq 1 ]; then
    echo "[$(date)] Running forget/prune for tag: $TAG"
    if restic forget $RETENTION --prune --tag "$TAG" --host "truenas"; then
        echo "[$(date)] Prune successful"
    else
        echo "[$(date)] WARNING: Prune failed"
    fi
fi

# ------------------------------------------------------------------
# Discord notification
# ------------------------------------------------------------------
TIMESTAMP=$(date -u +'%Y-%m-%d %H:%M UTC')

if [ "$BACKUP_OK" -eq 1 ]; then
    if [ -n "$MISSING_DATASETS" ]; then
        notify_discord "⚠️ **NAS restic backup completed with warnings** on \`truenas\` at ${TIMESTAMP}\n✓ ${FOUND_COUNT} datasets backed up\n✗ Missing:${MISSING_DATASETS}"
    else
        notify_discord "✅ **NAS restic backup succeeded** on \`truenas\` at ${TIMESTAMP}\nDatasets:${BACKUP_PATHS}"
    fi
    exit 0
else
    notify_discord "❌ **NAS restic backup FAILED** on \`truenas\` at ${TIMESTAMP}"
    exit 1
fi
