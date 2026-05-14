#!/bin/sh
set -e

CLEAN_PW="/tmp/restic-password-clean"
tr -d '[:space:]' < "$RESTIC_PASSWORD_FILE" > "$CLEAN_PW"
export RESTIC_PASSWORD_FILE="$CLEAN_PW"

#/backup/grafana /backup/openwebui
BACKUP_SOURCES="/backup/uptime-kuma /backup/vaultwarden /backup/adguard-conf /backup/obsidian"
RETENTION="--keep-daily 7 --keep-weekly 4 --keep-monthly 3"

echo "[$(date)] Starting backup to $RESTIC_REPOSITORY"

# Perform backup
if restic backup $BACKUP_SOURCES --tag "mac-mini"; then
    echo "Backup successful"
    # Prune old snapshots
    if restic forget $RETENTION --prune; then
        echo "Prune successful"
    else
        echo "WARNING: Prune failed"
    fi
    exit 0
else
    echo "Backup FAILED"
    exit 1
fi
