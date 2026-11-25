#!/bin/sh
set -eu

# ------------------------------------------------------------------
# Configuration (all from environment)
# ------------------------------------------------------------------
# Required:
#   RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, BACKUP_HOST
# Optional:
#   BACKUP_TAG            (default: $BACKUP_HOST)
#   BACKUP_LABEL          (display name in Discord, default: $BACKUP_HOST)
#   BACKUP_PATHS          space-separated static paths
#   ZFS_DATASETS          space/newline-separated dataset names
#   ZFS_SNAPSHOT_ROOT     default: /snapshots
#   STOP_LABEL            docker label; matching containers are stopped during backup
#   OFFSITE_REPOSITORY    if empty, offsite copy/prune is skipped
#   OFFSITE_USER, OFFSITE_PASSWORD_FILE required if OFFSITE_REPOSITORY is set
#   DISCORD_WEBHOOK_FILE  if missing, no notification is sent
#   RETENTION             default: --keep-daily 7 --keep-weekly 4 --keep-monthly 3

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is required}"
: "${BACKUP_HOST:?BACKUP_HOST is required}"

HOST="$BACKUP_HOST"
TAG="${BACKUP_TAG:-$HOST}"
LABEL="${BACKUP_LABEL:-$HOST}"
PRIMARY_REPO="$RESTIC_REPOSITORY"
OFFSITE_REPO="${OFFSITE_REPOSITORY:-}"
STATIC_PATHS="${BACKUP_PATHS:-}"
DATASETS="${ZFS_DATASETS:-}"
SNAP_ROOT="${ZFS_SNAPSHOT_ROOT:-/snapshots}"
STOP_LABEL="${STOP_LABEL:-}"
RETENTION="${RETENTION:---keep-daily 7 --keep-weekly 4 --keep-monthly 3}"

STOPPED_IDS=""

CLEAN_PW="/tmp/restic-password-clean"
( umask 077; tr -d '[:space:]' < "$RESTIC_PASSWORD_FILE" > "$CLEAN_PW" )
export RESTIC_PASSWORD_FILE="$CLEAN_PW"
BACKUP_OUT="/tmp/restic-backup-out.json"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
log() { echo "[$(date)] $*"; }

DISCORD_WEBHOOK=""
if [ -n "${DISCORD_WEBHOOK_FILE:-}" ] && [ -f "$DISCORD_WEBHOOK_FILE" ]; then
    DISCORD_WEBHOOK=$(tr -d '[:space:]' < "$DISCORD_WEBHOOK_FILE")
fi

notify_discord() {
    [ -n "$DISCORD_WEBHOOK" ] || return 0
    jq -n --arg c "$1" '{content: $c}' | \
        curl -s -X POST -H "Content-Type: application/json" \
             -d @- "$DISCORD_WEBHOOK" >/dev/null 2>&1 || true
}

restart_containers() {
    if [ -n "$STOPPED_IDS" ]; then
        log "Restarting containers..."
        echo "$STOPPED_IDS" | xargs docker start || log "WARNING: failed to restart some containers"
        STOPPED_IDS=""
    fi
}

# Safety net: containers always come back and the password copy is removed,
# even if the script is killed or fails mid-way.
cleanup() { restart_containers; rm -f "$CLEAN_PW" "$BACKUP_OUT"; }
trap cleanup EXIT
trap 'exit 143' INT TERM


OFFSITE_PASS=$(tr -d '[:space:]' < "$OFFSITE_PASSWORD_FILE")
restic_offsite() {
    RESTIC_REST_USERNAME="$OFFSITE_USER" RESTIC_REST_PASSWORD="$OFFSITE_PASS" \
        restic -r "$OFFSITE_REPO" "$@"
}

to_gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b / 1073741824 }'; }

get_latest_snapshot() { ls -1 "$1" 2>/dev/null | sort | tail -n 1; }

# ------------------------------------------------------------------
# 1. Resolve backup sources
# ------------------------------------------------------------------
SOURCES="$STATIC_PATHS"
MISSING_DATASETS=""
FOUND_COUNT=0

for dataset in $DATASETS; do
    parent="${SNAP_ROOT}/${dataset}"
    if [ ! -d "$parent" ]; then
        log "WARNING: $parent missing — skipping ${dataset}"
        MISSING_DATASETS="${MISSING_DATASETS} ${dataset}"
        continue
    fi
    latest=$(get_latest_snapshot "$parent")
    if [ -z "$latest" ]; then
        log "WARNING: no ZFS snapshot under $parent — skipping ${dataset}"
        MISSING_DATASETS="${MISSING_DATASETS} ${dataset}"
        continue
    fi
    log "Adding: [${dataset}] ← ${latest}"
    SOURCES="$SOURCES ${parent}/${latest}"
    FOUND_COUNT=$((FOUND_COUNT + 1))
done

# Fail if datasets were configured but none resolved, or nothing is configured at all
if [ -z "$(echo "$SOURCES" | tr -d '[:space:]')" ] || { [ -n "$DATASETS" ] && [ "$FOUND_COUNT" -eq 0 ] && [ -z "$STATIC_PATHS" ]; }; then
    log "FATAL: no backup sources found"
    notify_discord "❌ **Restic backup FAILED** \`${LABEL}\` $(date -u +'%Y-%m-%d %H:%M UTC') — no backup sources found"
    exit 1
fi

# ------------------------------------------------------------------
# 2. Stop labelled containers (optional)
# ------------------------------------------------------------------
if [ -n "$STOP_LABEL" ]; then
    log "Stopping containers with label '$STOP_LABEL'..."
    STOPPED_IDS=$(docker ps --filter "label=$STOP_LABEL" --format '{{.ID}}')
    if [ -n "$STOPPED_IDS" ]; then
        echo "$STOPPED_IDS" | xargs docker stop
    fi
fi

# ------------------------------------------------------------------
# 3. Backup to primary
# ------------------------------------------------------------------
log "Starting backup to primary: $PRIMARY_REPO"
log "Sources: $SOURCES"

PRIMARY_OK=0
SNAPSHOT_ID=""
SNAPSHOT_BYTES=0
BACKUP_RC=0

# shellcheck disable=SC2086
restic backup --json $SOURCES --host "$HOST" --tag "$TAG" > "$BACKUP_OUT" || BACKUP_RC=$?

# exit 0 = ok, exit 3 = snapshot created but some files unreadable (treat as success)
if [ "$BACKUP_RC" -eq 0 ] || [ "$BACKUP_RC" -eq 3 ]; then
    PRIMARY_OK=1
    [ "$BACKUP_RC" -eq 3 ] && log "WARNING: some files could not be read"
    log "✓ Primary backup succeeded"

    SUMMARY=$(jq -c 'select(.message_type=="summary")' "$BACKUP_OUT" | tail -n 1)
    if [ -n "$SUMMARY" ]; then
        SNAPSHOT_ID=$(printf '%s' "$SUMMARY" | jq -r '.snapshot_id // empty')
        SNAPSHOT_BYTES=$(printf '%s' "$SUMMARY" | jq -r '.total_bytes_processed // 0')
    fi
else
    log "✗ Primary backup FAILED (exit $BACKUP_RC)"
fi

# ------------------------------------------------------------------
# 4. Restart containers right away (don't wait for prune/copy)
# ------------------------------------------------------------------
restart_containers

# ------------------------------------------------------------------
# 5. Prune primary
# ------------------------------------------------------------------
if [ "$PRIMARY_OK" -eq 1 ]; then
    log "Pruning primary repository..."
    # shellcheck disable=SC2086
    if restic forget $RETENTION --prune --host "$HOST" --tag "$TAG" --group-by host,tags; then
        log "✓ Primary prune successful"
    else
        log "WARNING: primary prune failed"
    fi
fi

# ------------------------------------------------------------------
# 6. Copy + prune offsite (optional)
# ------------------------------------------------------------------
OFFSITE_OK=0
OFFSITE_ENABLED=0
[ -n "$OFFSITE_REPO" ] && OFFSITE_ENABLED=1

if [ "$OFFSITE_ENABLED" -eq 1 ] && [ "$PRIMARY_OK" -eq 1 ]; then
    log "Copying snapshot to offsite: $OFFSITE_REPO"
    if restic_offsite copy --from-repo "$PRIMARY_REPO" \
            --from-password-file "$RESTIC_PASSWORD_FILE" \
            --host "$HOST" --tag "$TAG" latest; then
        log "✓ Offsite copy succeeded"
        OFFSITE_OK=1
    else
        log "✗ Offsite copy FAILED"
    fi

    if [ "$OFFSITE_OK" -eq 1 ]; then
        log "Pruning offsite repository..."
        # shellcheck disable=SC2086
        if restic_offsite forget $RETENTION --prune --host "$HOST" --tag "$TAG" --group-by host,tags; then
            log "✓ Offsite prune successful"
        else
            log "WARNING: offsite prune failed"
        fi
    fi
fi

# ------------------------------------------------------------------
# 7. Sizes
# ------------------------------------------------------------------
SIZE_LINE=""
if [ "$PRIMARY_OK" -eq 1 ] && [ -n "$SNAPSHOT_ID" ]; then
    SIZE_LINE="📦 Snapshot $(printf '%s' "$SNAPSHOT_ID" | cut -c1-8): $(to_gib "$SNAPSHOT_BYTES") GiB"
    log "$SIZE_LINE"
fi

# ------------------------------------------------------------------
# 8. Discord notification
# ------------------------------------------------------------------
TIMESTAMP=$(date -u +'%Y-%m-%d %H:%M UTC')

if [ "$PRIMARY_OK" -eq 1 ]; then
    PRIMARY_STATUS="✅ Primary: success"
else
    PRIMARY_STATUS="❌ Primary: FAILED"
fi

if [ "$OFFSITE_ENABLED" -eq 0 ]; then
    OFFSITE_STATUS="➖ Offsite: not configured"
elif [ "$PRIMARY_OK" -eq 0 ]; then
    OFFSITE_STATUS="⏭️ Offsite: skipped (primary failed)"
elif [ "$OFFSITE_OK" -eq 1 ]; then
    OFFSITE_STATUS="✅ Offsite: success"
else
    OFFSITE_STATUS="❌ Offsite: FAILED"
fi

MESSAGE="**Restic backup** \`${LABEL}\` ${TIMESTAMP}
${PRIMARY_STATUS} · ${OFFSITE_STATUS}"
[ -n "$SIZE_LINE" ] && MESSAGE="${MESSAGE}
${SIZE_LINE}"
[ -n "$MISSING_DATASETS" ] && MESSAGE="${MESSAGE}
⚠️ Missing datasets:${MISSING_DATASETS}"

notify_discord "$MESSAGE"

# ------------------------------------------------------------------
# Exit code (doco-cd reads this)
# ------------------------------------------------------------------
[ "$PRIMARY_OK" -eq 1 ]
