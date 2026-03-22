#!/usr/bin/env bash
# backup.sh — Homelab backup orchestrator
# Lives at the repo root, parallel to the doco-cd docker-compose.yml
# Run as: sudo ./backup.sh
#
# Step 1: discover_projects  — find all compose projects while everything is running
# Step 2: discover_mounts    — inspect containers, build bind/named volume lists
# Step 3: teardown           — stop doco-cd first, then all other stacks
# Step 4: backup_volumes     — backup_bind_mounts + backup_named_volumes
# Step 5: (TODO) rsync to NAS
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[backup]${NC} $*"; }
ok()   { echo -e "${GREEN}[  ok  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ warn ]${NC} $*"; }
die()  { echo -e "${RED}[ fail ]${NC} $*" >&2; exit 1; }

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCOCD_COMPOSE="${SCRIPT_DIR}/docker-compose.yml"
DOCOCD_PROJECT="doco-cd"
BACKUP_ROOT="${SCRIPT_DIR}/backups"

# Bind mount paths to skip during discovery.
# Prefix match: a path is skipped if it equals an entry OR starts with entry + "/"
# Add entries here if you want to exclude additional paths (e.g. large model dirs).
SKIP_BIND_PREFIXES=(
    "/"                         # root filesystem (cAdvisor)
    "/rootfs"                   # Docker Desktop alias for root filesystem
    "/proc"                     # live kernel process data — not real files
    "/sys"                      # live kernel hardware data — not real files
    "/dev"                      # raw device files
    "/var/run"                  # Docker socket and other runtime sockets
    "/host_mnt"                 # Docker Desktop macOS translation of host paths
    "/var/lib/docker"           # Docker internal storage — backed up via volumes instead
    "/etc/localtime"            # OS timezone file injected by Docker
    "/etc/hosts"                # OS hosts file injected by Docker
    "/etc/resolv.conf"          # OS DNS config injected by Docker
    "${SCRIPT_DIR}/doco-cd-data" # doco-cd Git cache — re-cloned from GitHub on restart
)

# ── Preflight ─────────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
command -v jq     >/dev/null 2>&1 || die "jq not found — install with: brew install jq"
[[ -f "$DOCOCD_COMPOSE" ]]        || die "Root docker-compose.yml not found at: $DOCOCD_COMPOSE"

# ── Globals ───────────────────────────────────────────────────────────────────
# All compose project names discovered (excluding doco-cd)
PROJECTS=()

# "Dict" entries encoded as "project|value" — bash 3.2 has no associative arrays
# BIND_MOUNTS entries:   "project|/absolute/source/path"
# NAMED_VOLUMES entries: "project|volume_name"
BIND_MOUNTS=()
NAMED_VOLUMES=()

# ── discover_projects ─────────────────────────────────────────────────────────
# Snapshot all running compose projects before anything is stopped.
discover_projects() {
    log "=== Step 1: Discover projects ==="
    echo

    while IFS= read -r line; do
        [[ -n "$line" ]] && PROJECTS+=("$line")
    done < <(
        docker compose ls --format json 2>/dev/null \
        | jq -r '.[] | select(.Status != "exited") | select(.Name != "'"$DOCOCD_PROJECT"'") | .Name'
    )

    if [[ ${#PROJECTS[@]} -eq 0 ]]; then
        warn "No running compose stacks found (excluding doco-cd)"
    else
        ok "Found ${#PROJECTS[@]} stack(s): ${PROJECTS[*]}"
    fi
    echo
}

# ── should_skip_bind ─────────────────────────────────────────────────────────
# Returns 0 (true) if the given path should be excluded from backup.
# A path is skipped if it exactly matches a prefix or starts with prefix + "/"
should_skip_bind() {
    local src="$1"

    for prefix in "${SKIP_BIND_PREFIXES[@]}"; do
        if [[ "$src" == "$prefix" || "$src" == "$prefix/"* ]]; then
            return 0
        fi
    done

    return 1
}

# ── discover_mounts ───────────────────────────────────────────────────────────
# For each project, inspect all containers and record every bind mount and
# named volume into BIND_MOUNTS[] and NAMED_VOLUMES[].
# Deduplication happens here so backup functions get a clean list.
# Bind mounts are filtered through should_skip_bind before being recorded.
discover_mounts() {
    log "=== Step 2: Discover mounts ==="
    echo

    if [[ ${#PROJECTS[@]} -eq 0 ]]; then
        warn "No projects to inspect"
        echo
        return
    fi

    for project in "${PROJECTS[@]}"; do
        log "Inspecting: ${project}"

        local container_ids
        container_ids=$(docker ps --filter "label=com.docker.compose.project=${project}" -q)

        if [[ -z "$container_ids" ]]; then
            warn "  No containers found for $project"
            echo
            continue
        fi

        local mounts_json
        mounts_json=$(echo "$container_ids" | xargs docker inspect | jq -c '.[] | .Mounts[]')

        if [[ -z "$mounts_json" ]]; then
            warn "  No mounts found for $project"
            echo
            continue
        fi

        while IFS= read -r mount; do
            local mount_type
            mount_type=$(echo "$mount" | jq -r '.Type')

            case "$mount_type" in

                bind)
                    local src
                    src=$(echo "$mount" | jq -r '.Source')

                    should_skip_bind "$src" && continue

                    # Deduplication
                    local dup=false
                    for entry in "${BIND_MOUNTS[@]:-}"; do
                        [[ "${entry#*|}" == "$src" ]] && dup=true && break
                    done
                    if $dup; then
                        continue
                    fi

                    BIND_MOUNTS+=("${project}|${src}")
                    ok "  [bind]   $src"
                    ;;

                volume)
                    local vol_name
                    vol_name=$(echo "$mount" | jq -r '.Name')

                    # Skip anonymous volumes (64-char hex)
                    if [[ "$vol_name" =~ ^[a-f0-9]{64}$ ]]; then
                        continue
                    fi

                    # Deduplication
                    local dup=false
                    for entry in "${NAMED_VOLUMES[@]:-}"; do
                        [[ "${entry#*|}" == "$vol_name" ]] && dup=true && break
                    done
                    if $dup; then
                        continue
                    fi

                    NAMED_VOLUMES+=("${project}|${vol_name}")
                    ok "  [volume] $vol_name"
                    ;;

                *)
                    # tmpfs etc — nothing to back up
                    continue
                    ;;
            esac

        done <<< "$mounts_json"

        echo
    done

    log "Discovery complete — ${#BIND_MOUNTS[@]} bind mount(s), ${#NAMED_VOLUMES[@]} named volume(s) queued"
    echo
}

# ── teardown ──────────────────────────────────────────────────────────────────
# Stops doco-cd first so it can't redeploy mid-backup, then stops all other
# stacks by container label (compose file paths are unreachable on macOS host).
teardown() {
    log "=== Step 3: Teardown ==="
    echo

    log "Stopping doco-cd first (prevents redeploy during backup)..."
    if docker compose -f "$DOCOCD_COMPOSE" ps --quiet 2>/dev/null | grep -q .; then
        docker compose -f "$DOCOCD_COMPOSE" stop
        ok "doco-cd stopped"
    else
        warn "doco-cd was not running (skipping)"
    fi
    echo

    if [[ ${#PROJECTS[@]} -eq 0 ]]; then
        warn "No stacks to stop"
        echo
        return
    fi

    for project in "${PROJECTS[@]}"; do
        log "Stopping: ${project}"

        local container_ids
        container_ids=$(docker ps --filter "label=com.docker.compose.project=${project}" -q)

        if [[ -z "$container_ids" ]]; then
            warn "  $project — no running containers (already stopped?)"
            continue
        fi

        if echo "$container_ids" | xargs docker stop > /dev/null; then
            ok "  $project stopped"
        else
            warn "  $project stop returned non-zero"
        fi
    done

    echo
    ok "All stacks stopped. Volumes are intact."
    echo
}

# ── backup_bind_mounts ────────────────────────────────────────────────────────
# Tars each bind mount source directory directly — these are real paths on the
# Mac filesystem so no Alpine intermediary is needed.
backup_bind_mounts() {
    if [[ ${#BIND_MOUNTS[@]} -eq 0 ]]; then
        warn "No bind mounts to back up"
        return
    fi

    log "Backing up bind mounts..."

    for entry in "${BIND_MOUNTS[@]}"; do
        local project="${entry%%|*}"
        local src="${entry#*|}"

        # Sanitise src into a filename: strip leading slash, replace / with _
        local safe_name
        safe_name=$(echo "$src" | sed 's|^/||' | sed 's|/|_|g')
        local out_file="${BACKUP_DIR}/bind_${project}_${safe_name}.tar.gz"

        log "  $src"
        if tar czf "$out_file" -C "$src" . 2>/dev/null; then
            ok "    -> $(basename "$out_file")"
        else
            warn "    Failed: $src"
        fi
    done

    echo
}

# ── backup_named_volumes ──────────────────────────────────────────────────────
# Named volumes live inside Docker's Linux VM and can't be reached directly
# from macOS — we spin up a temporary Alpine container which *can* see them,
# and pipe the contents out as a tar archive into the backup dir.
backup_named_volumes() {
    if [[ ${#NAMED_VOLUMES[@]} -eq 0 ]]; then
        warn "No named volumes to back up"
        return
    fi

    log "Backing up named volumes..."

    for entry in "${NAMED_VOLUMES[@]}"; do
        local project="${entry%%|*}"
        local vol_name="${entry#*|}"
        local out_file="${BACKUP_DIR}/vol_${project}_${vol_name}.tar.gz"

        log "  $vol_name"
        if docker run --rm \
            -v "${vol_name}:/source:ro" \
            -v "${BACKUP_DIR}:/backup" \
            alpine tar czf "/backup/$(basename "$out_file")" -C /source . 2>/dev/null; then
            ok "    -> $(basename "$out_file")"
        else
            warn "    Failed: $vol_name"
        fi
    done

    echo
}

# ── backup_volumes ────────────────────────────────────────────────────────────
# Orchestrates both backup functions under a shared timestamped directory.
backup_volumes() {
    log "=== Step 4: Backup volumes ==="
    echo

    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    chown -R "${SUDO_USER:-$USER}:staff" "$BACKUP_ROOT"
    chmod -R 755 "$BACKUP_ROOT"
    log "Destination: $BACKUP_DIR"
    echo

    backup_bind_mounts
    backup_named_volumes

    log "All backups written to: $BACKUP_DIR"
    ls -lh "$BACKUP_DIR"
    echo
}

# ── Main ──────────────────────────────────────────────────────────────────────
log "Homelab backup — $(date '+%Y-%m-%d %H:%M:%S')"
echo

discover_projects
discover_mounts
teardown
backup_volumes
