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
# 2. Backup
# ------------------------------------------------------------------
echo "[$(date)] Starting backup to $RESTIC_REPOSITORY"
BACKUP_OK=0
if restic backup $BACKUP_SOURCES --tag "mac-mini"; then
    echo "Backup successful"
    BACKUP_OK=1
    # Prune old snapshots
    if restic forget $RETENTION --prune; then
        echo "Prune successful"
    else
        echo "WARNING: Prune failed"
    fi
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

# --- 4. Send Discord notification ---
if [ "$BACKUP_OK" -eq 1 ]; then
    notify_discord "✅ **Restic backup succeeded** on \`$HOSTNAME\` at $(date -u +'%Y-%m-%d %H:%M UTC')"
else
    notify_discord "❌ **Restic backup FAILED** on \`$HOSTNAME\` at $(date -u +'%Y-%m-%d %H:%M UTC')"
fi

# ------------------------------------------------------------------
# Exit with appropriate code (doco‑cd reads this)
# ------------------------------------------------------------------
if [ "$BACKUP_OK" -eq 1 ]; then
    exit 0
else
    exit 1
fi
