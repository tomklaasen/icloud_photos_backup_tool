#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    echo "Create it from backup.conf" >&2
    exit 1
fi
source "$CONFIG_FILE"

# Defaults
ICLOUDPD_BIN="${ICLOUDPD_BIN:-/home/tomklaasen/.local/bin/icloudpd}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/usb/icloud_photos_backup}"
USERNAME="${USERNAME:-tomk@tomk.be}"
UNTIL_FOUND="${UNTIL_FOUND:-500}"
SHARED_LIBRARY="${SHARED_LIBRARY:-}"
LOG_FILE="${LOG_FILE:-}"
LOG_MAX_SIZE_KB="${LOG_MAX_SIZE_KB:-10240}"
LOG_KEEP="${LOG_KEEP:-5}"
HC_PING_URL="${HC_PING_URL:-}"

# --- Logging ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

hc_ping() {
    if [[ -n "$HC_PING_URL" ]]; then
        local suffix="${1:-}"
        local body="${2:-}"
        local url="$HC_PING_URL"
        [[ -n "$suffix" ]] && url="$url/$suffix"
        if [[ -n "$body" ]]; then
            curl -fsS --max-time 10 --retry 3 --data-raw "$body" "$url" > /dev/null 2>&1 || true
        else
            curl -fsS --max-time 10 --retry 3 "$url" > /dev/null 2>&1 || true
        fi
    fi
}

# --- Log rotation ---
rotate_logs() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return

    local size_kb
    size_kb=$(du -k "$log_file" | cut -f1)

    if (( size_kb >= LOG_MAX_SIZE_KB )); then
        [[ -f "$log_file.$LOG_KEEP" ]] && rm -f "$log_file.$LOG_KEEP"
        for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
            [[ -f "$log_file.$i" ]] && mv "$log_file.$i" "$log_file.$((i + 1))"
        done
        mv "$log_file" "$log_file.1"
    fi
}

# Set up file logging if LOG_FILE is configured
if [[ -n "$LOG_FILE" ]]; then
    rotate_logs "$LOG_FILE"
    exec >> "$LOG_FILE" 2>&1
fi

# --- Verify prerequisites ---
if [[ ! -x "$ICLOUDPD_BIN" ]]; then
    log "ERROR: icloudpd binary not found or not executable: $ICLOUDPD_BIN"
    exit 1
fi

if [[ -n "$HC_PING_URL" ]] && ! command -v curl &>/dev/null; then
    log "ERROR: curl is not installed (required for HC_PING_URL)."
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# --- Start ---
log "===== iCloud Photos backup starting ====="
hc_ping start

failed=0
summary=""

# --- Shared library backup ---
if [[ -n "$SHARED_LIBRARY" ]]; then
    log "Running shared library backup (library: $SHARED_LIBRARY)..."
    if "$ICLOUDPD_BIN" -d "$BACKUP_DIR" --username "$USERNAME" --until-found "$UNTIL_FOUND" --library="$SHARED_LIBRARY" 2>&1; then
        log "Shared library backup completed successfully."
        summary+="Shared library: OK"
    else
        log "ERROR: Shared library backup failed (exit code: $?)."
        summary+="Shared library: FAILED"
        failed=$((failed + 1))
    fi
else
    log "Skipping shared library backup (SHARED_LIBRARY not set)."
fi

# --- Personal library backup ---
log "Running personal library backup..."
if "$ICLOUDPD_BIN" -d "$BACKUP_DIR" --username "$USERNAME" --until-found "$UNTIL_FOUND" 2>&1; then
    log "Personal library backup completed successfully."
    summary+=", Personal library: OK"
else
    log "ERROR: Personal library backup failed (exit code: $?)."
    summary+=", Personal library: FAILED"
    failed=$((failed + 1))
fi

# --- Summary ---
echo
log "===== Backup complete ====="
log "$summary"

if (( failed > 0 )); then
    hc_ping fail "$summary"
else
    hc_ping "" "$summary"
fi
