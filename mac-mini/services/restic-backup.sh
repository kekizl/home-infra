#!/bin/sh
set -e

# Ensure password has no trailing whitespace
CLEAN_PW="/tmp/restic-password-clean"
tr -d '[:space:]' < "$RESTIC_PASSWORD_FILE" > "$CLEAN_PW"
export RESTIC_PASSWORD_FILE="$CLEAN_PW"

DISCORD_WEBHOOK_FILE="${DISCORD_WEBHOOK_FILE}"
DISCORD_WEBHOOK=""
if [ -f "$DISCORD_WEBHOOK_FILE" ]; then
    DISCORD_WEBHOOK=$(tr -d '[:space:]' < "$DISCORD_WEBHOOK_FILE")
fi

# --- Notification helper ---
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

BACKUP_SOURCES="/backup/openwebui /backup/grafana /backup/uptime-kuma /backup/vaultwarden /backup/adguard-conf /backup/obsidian"
RETENTION="--keep-daily 7 --keep-weekly 4 --keep-monthly 3"
LABEL="docker-volume-backup.stop-during-backup=true"

# ------------------------------------------------------------------
# 1. Stop labelled containers
# ------------------------------------------------------------------
echo "[$(date)] Stopping containers with label '$LABEL'..."
STOPPED_IDS=$(docker ps --filter "label=$LABEL" --format '{{.ID}}')
if [ -n "$STOPPED_IDS" ]; then
    echo "$STOPPED_IDS" | xargs docker stop
fi

# ------------------------------------------------------------------
# 2. Backup to primary repository
# ------------------------------------------------------------------
echo "[$(date)] Starting backup to primary: $PRIMARY_REPO"
PRIMARY_OK=0
if restic backup $BACKUP_SOURCES --host mac-mini --tag "mac-mini"; then
    echo "Backup successful"
    PRIMARY_OK=1
else
    echo "Backup FAILED"
fi

# ------------------------------------------------------------------
# 3. Always restart the containers
# ------------------------------------------------------------------
if [ -n "$STOPPED_IDS" ]; then
    echo "[$(date)] Restarting containers..."
    echo "$STOPPED_IDS" | xargs docker start
fi

# ------------------------------------------------------------------
# 4. Prune primary repository (only if backup succeeded)
# ------------------------------------------------------------------
if [ "$PRIMARY_OK" -eq 1 ]; then
    echo "[$(date)] Pruning primary repository..."
    if restic forget $RETENTION --prune; then
        echo "✓ Primary prune successful"
    else
        echo "WARNING: Primary prune failed"
    fi
fi

# ------------------------------------------------------------------
# 5. Copy to offsite repository (only if primary backup succeeded)
# ------------------------------------------------------------------
OFFSITE_OK=0
if [ "$PRIMARY_OK" -eq 1 ]; then
    echo "[$(date)] Copying snapshot to offsite: $OFFSITE_REPO"
    if restic -r "$OFFSITE_REPO" --password-file "$RESTIC_PASSWORD_FILE" \
        copy --from-repo "$PRIMARY_REPO" --from-password-file "$RESTIC_PASSWORD_FILE" latest; then
        echo "✓ Offsite copy succeeded"
        OFFSITE_OK=1
    else
        echo "✗ Offsite copy FAILED"
    fi
else
    echo "[$(date)] Skipping offsite copy — primary backup failed"
fi

# ------------------------------------------------------------------
# 6. Prune offsite repository (only if copy succeeded)
# ------------------------------------------------------------------
if [ "$OFFSITE_OK" -eq 1 ]; then
    echo "[$(date)] Pruning offsite repository..."
    if restic -r "$OFFSITE_REPO" --password-file "$RESTIC_PASSWORD_FILE" \
        forget $RETENTION --prune --tag "mac-mini" --host "mac-mini"; then
        echo "✓ Offsite prune successful"
    else
        echo "WARNING: Offsite prune failed"
    fi
fi

# ------------------------------------------------------------------
# 7. Discord notification — single message with both states
# ------------------------------------------------------------------
TIMESTAMP=$(date -u +'%Y-%m-%d %H:%M UTC')

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

MESSAGE="**Restic backup** \`mac-mini\` ${TIMESTAMP} — ${PRIMARY_STATUS} · ${OFFSITE_STATUS}"
notify_discord "$MESSAGE"

# ------------------------------------------------------------------
# Exit with appropriate code (doco‑cd reads this)
# ------------------------------------------------------------------
if [ "$PRIMARY_OK" -eq 1 ]; then
    exit 0
else
    exit 1
fi
