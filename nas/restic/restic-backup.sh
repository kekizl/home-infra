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
PRIMARY_REPO="${RESTIC_REPOSITORY}"
OFFSITE_REPO="${OFFSITE_REPOSITORY}"

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
echo "[$(date)] Starting ZFS snapshot backup to primary: $PRIMARY_REPO"
echo "[$(date)] Paths: $BACKUP_PATHS"

PRIMARY_OK=0
if restic backup $BACKUP_PATHS --tag "$TAG" --host "truenas"; then
    echo "[$(date)] ✓ Primary backup succeeded (${FOUND_COUNT} datasets)"
    PRIMARY_OK=1
else
    echo "[$(date)] ✗ Primary backup FAILED"
fi

# ------------------------------------------------------------------
# Prune primary repo (only if backup succeeded)
# ------------------------------------------------------------------
if [ "$PRIMARY_OK" -eq 1 ]; then
    echo "[$(date)] Pruning primary repository..."
    if restic forget $RETENTION --prune --tag "$TAG" --host "truenas"; then
        echo "[$(date)] ✓ Primary prune successful"
    else
        echo "[$(date)] WARNING: Primary prune failed"
    fi
fi

# ------------------------------------------------------------------
# Copy to offsite repo (only if primary backup succeeded)
# ------------------------------------------------------------------
OFFSITE_OK=0
if [ "$PRIMARY_OK" -eq 1 ]; then
    echo "[$(date)] Copying snapshot to offsite: $OFFSITE_REPO"
    if restic -r "$OFFSITE_REPO" --password-file "$RESTIC_PASSWORD_FILE" \
        copy --from-repo "$PRIMARY_REPO" --from-password-file "$RESTIC_PASSWORD_FILE" latest; then
        echo "[$(date)] ✓ Offsite copy succeeded"
        OFFSITE_OK=1
    else
        echo "[$(date)] ✗ Offsite copy FAILED"
    fi
else
    echo "[$(date)] Skipping offsite copy — primary backup failed"
fi

# ------------------------------------------------------------------
# Prune offsite repo (only if copy succeeded)
# ------------------------------------------------------------------
if [ "$OFFSITE_OK" -eq 1 ]; then
    echo "[$(date)] Pruning offsite repository..."
    if restic -r "$OFFSITE_REPO" --password-file "$RESTIC_PASSWORD_FILE" \
        forget $RETENTION --prune --tag "$TAG" --host "truenas"; then
        echo "[$(date)] ✓ Offsite prune successful"
    else
        echo "[$(date)] WARNING: Offsite prune failed"
    fi
fi

# ------------------------------------------------------------------
# Discord notification — single message with both states
# ------------------------------------------------------------------
TIMESTAMP=$(date -u +'%Y-%m-%d %H:%M UTC')

# Build status strings
if [ "$PRIMARY_OK" -eq 1 ]; then
    PRIMARY_STATUS="✅ Primary: success"
else
    PRIMARY_STATUS="❌ Primary: FAILED"
fi

if [ "$PRIMARY_OK" -eq 0 ]; then
    OFFSITE_STATUS="⏭️ Offsite: skipped (primary failed)"
elif [ "$OFFSITE_OK" -eq 1 ]; then
    OFFSITE_STATUS="✅ Offsite: success"
else
    OFFSITE_STATUS="❌ Offsite: FAILED"
fi

# Build warning about missing datasets
if [ -n "$MISSING_DATASETS" ]; then
    WARNING="\n⚠️ Missing datasets:${MISSING_DATASETS}"
else
    WARNING=""
fi

MESSAGE="**NAS restic backup report** \`truenas\` ${TIMESTAMP}
${PRIMARY_STATUS}
${OFFSITE_STATUS}${WARNING}"

notify_discord "$MESSAGE"

# ------------------------------------------------------------------
# Exit code — fail if primary failed
# ------------------------------------------------------------------
if [ "$PRIMARY_OK" -eq 1 ]; then
    exit 0
else
    exit 1
fi
