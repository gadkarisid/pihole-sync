#!/bin/bash
# pihole_sync.sh - Pi-hole v6 gravity.db sync script
# Compatible with Pi-hole v6 only
set -euo pipefail

###########################
# BEGIN CONFIGURATION
###########################
NODE_NAME="<ADD NAME>"
NODE_TYPE="<ADD ROLE>"          # primary | secondary
LOCAL_DIR="/etc/pihole"
REMOTE_DIR="/media/NAS/backups/pihole_sync"
SENTINEL_FILE="${REMOTE_DIR}/.sync_ready"
TEMP_DIR="/tmp/pihole_sync"
FILES=(gravity.db)
###########################
# END CONFIGURATION
###########################

LOG_TAG="pihole_sync[${NODE_NAME}]"
SYSLOG_START_LINE=$(wc -l < /var/log/syslog)

log() { logger "${LOG_TAG}: $*"; }

die() { log "ERROR: $*"; write_log; exit 1; }

validate_config() {
    [[ "$NODE_NAME" == "<ADD NODE NAME>" ]] && { logger "pihole_sync: ERROR - NODE_NAME not configured"; exit 1; }
    [[ "$NODE_TYPE" == "<ADD ROLE>" ]] && { logger "pihole_sync: ERROR - NODE_TYPE not configured"; exit 1; }
    [[ "$NODE_TYPE" =~ ^(primary|secondary)$ ]] || { logger "pihole_sync: ERROR - NODE_TYPE must be 'primary' or 'secondary', got '${NODE_TYPE}'"; exit 1; }
}

check_mount() {
    mountpoint -q "/media/NAS/backups" || die "NFS mount not available at /media/NAS/backups"
    [[ -d "$REMOTE_DIR" ]] || die "Sync directory not found: ${REMOTE_DIR}"
    [[ -w "$REMOTE_DIR" ]] || die "Sync directory not writable: ${REMOTE_DIR}"
}

checksum() {
    sha256sum "$1" | awk '{print $1}'
}

sqlite_backup() {
    local src="$1" dst="$2"
    sqlite3 "$src" ".backup '${dst}'" || die "sqlite3 backup failed for ${src}"
}

write_log() {
    local current_lines
    local log_file
    current_lines=$(wc -l < /var/log/syslog)
    log_file="${REMOTE_DIR}/pihole_sync-${NODE_NAME}-$(date '+%Y-%m-%d').log"
    local new_lines=$(( current_lines - SYSLOG_START_LINE ))
    if [[ "$new_lines" -gt 0 ]]; then
        tail -n "$new_lines" /var/log/syslog | \
            grep -F "${LOG_TAG}" >> "$log_file" || true
        find "${REMOTE_DIR}" -maxdepth 1 -name "pihole_sync-${NODE_NAME}-*.log" \
            ! -name "pihole_sync-${NODE_NAME}-$(date '+%Y-%m-%d').log" -delete
    fi
}

cleanup() {
    rm -rf "$TEMP_DIR"
}

sync_primary() {
    local force="${1:-}"
    log "Role: primary"
    mkdir -p "$TEMP_DIR"

    for FILE in "${FILES[@]}"; do
        local local_file="${LOCAL_DIR}/${FILE}"
        local remote_file="${REMOTE_DIR}/${FILE}"
        local temp_file="${TEMP_DIR}/${FILE}"
        local sidecar_file="${remote_file}.sha256"

        [[ -f "$local_file" ]] || die "Source file not found: ${local_file}"

        log "Creating safe backup of ${FILE}"
        sqlite_backup "$local_file" "$temp_file"

        local local_sum
        local_sum=$(checksum "$temp_file")

        if [[ "$force" == "-f" ]]; then
            log "Force flag set, syncing ${FILE}"
            cp -- "$temp_file" "$remote_file"
            echo "$local_sum" > "$sidecar_file"
            log "${FILE} synced (forced)"
        elif [[ ! -f "$remote_file" ]]; then
            log "${FILE} not present on NAS, syncing"
            cp -- "$temp_file" "$remote_file"
            echo "$local_sum" > "$sidecar_file"
            log "${FILE} synced (initial)"
        else
            local remote_sum
            remote_sum=$(cat "$sidecar_file" 2>/dev/null || echo "none")
            if [[ "$local_sum" != "$remote_sum" ]]; then
                log "${FILE} content differs, syncing"
                cp -- "$temp_file" "$remote_file"
                echo "$local_sum" > "$sidecar_file"
                log "${FILE} synced"
            else
                log "${FILE} up to date, skipping"
            fi
        fi
    done

    touch "$SENTINEL_FILE"
    log "Sentinel file written"
}

sync_secondary() {
    local force="${1:-}"
    log "Role: secondary"

    local waited=0
    local wait_interval=5
    local wait_max=60
    while [[ ! -f "$SENTINEL_FILE" ]]; do
        if [[ "$waited" -ge "$wait_max" ]]; then
            die "Sentinel file not seen after ${wait_max}s, aborting"
        fi
        log "Waiting for sentinel file (${waited}/${wait_max}s)..."
        sleep "$wait_interval"
        (( waited += wait_interval ))
    done
    log "Sentinel file detected"
    rm -f "$SENTINEL_FILE"

    local update_needed=0

    for FILE in "${FILES[@]}"; do
        local local_file="${LOCAL_DIR}/${FILE}"
        local remote_file="${REMOTE_DIR}/${FILE}"
        local sidecar_file="${remote_file}.sha256"

        [[ -f "$remote_file" ]] || die "Remote file not found: ${remote_file}"

        if [[ "$force" == "-f" ]]; then
            log "Force flag set, syncing ${FILE}"
            sudo cp -- "$remote_file" "$local_file"
            log "${FILE} synced (forced)"
            update_needed=$(( update_needed + 1 ))
        elif [[ ! -f "$local_file" ]]; then
            log "${FILE} not present locally, syncing"
            sudo cp -- "$remote_file" "$local_file"
            log "${FILE} synced (initial)"
            update_needed=$(( update_needed + 1 ))
        else
            local local_sum remote_sum
            local_sum=$(checksum "$local_file")
            remote_sum=$(cat "$sidecar_file" 2>/dev/null || echo "none")
            if [[ "$local_sum" != "$remote_sum" ]]; then
                log "${FILE} content differs, syncing"
                sudo cp -- "$remote_file" "$local_file"
                log "${FILE} synced"
                update_needed=$(( update_needed + 1 ))
            else
                log "${FILE} up to date, skipping"
            fi
        fi
    done

    if [[ "$update_needed" -ge 1 ]]; then
        log "Reloading Pi-hole lists"
        sudo pihole reloadlists
        log "Pi-hole lists reloaded"
    fi
}

# Main
trap cleanup EXIT

log "Sync starting"
validate_config
check_mount

case "$NODE_TYPE" in
    primary)   sync_primary "${1:-}"   ;;
    secondary) sync_secondary "${1:-}" ;;
esac

log "Sync complete"
write_log
