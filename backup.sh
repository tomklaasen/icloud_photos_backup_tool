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

# Defaults for optional settings
SHARED_LIBRARY="${SHARED_LIBRARY:-}"
COOKIE_DIRECTORY="${COOKIE_DIRECTORY:-$HOME/.pyicloud}"
SESSION_MAX_AGE_DAYS="${SESSION_MAX_AGE_DAYS:-14}"
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

# --- Check session freshness ---
# icloudpd stores session files as <username_without_punctuation>.session
# in the cookie directory. If the session file is older than SESSION_MAX_AGE_DAYS,
# skip the backup to avoid triggering MFA push notifications.
session_file="$COOKIE_DIRECTORY/$(echo "$USERNAME" | tr -d '.@').session"
if [[ -f "$session_file" ]]; then
    session_age_sec=$(( $(date +%s) - $(stat --format='%Y' "$session_file") ))
    session_age_days=$(( session_age_sec / 86400 ))
    if (( session_age_days >= SESSION_MAX_AGE_DAYS )); then
        msg="Skipped: session expired (last refreshed ${session_age_days} days ago). Re-authenticate with: $ICLOUDPD_BIN --auth-only --username $USERNAME --cookie-directory $COOKIE_DIRECTORY"
        log "$msg"
        hc_ping fail "$msg"
        exit 0
    fi
else
    msg="Skipped: session file not found at $session_file. Authenticate with: $ICLOUDPD_BIN --auth-only --username $USERNAME --cookie-directory $COOKIE_DIRECTORY"
    log "$msg"
    hc_ping fail "$msg"
    exit 0
fi

# --- Start ---
log "===== iCloud Photos backup starting ====="
hc_ping start

failed=0
summary=""
total_new=0
tmpout=$(mktemp)
trap 'rm -f "$tmpout"' EXIT

# Count new downloads from icloudpd output.
# icloudpd logs "Downloading /path/to/file" for each new file (distinct from
# the summary line "Downloading ??? original photos and videos to ...").
count_new_downloads() {
    grep -c 'Downloading /' "$tmpout" 2>/dev/null || true
}

# --- Shared library backup ---
shared_new=0
if [[ -n "$SHARED_LIBRARY" ]]; then
    log "Running shared library backup (library: $SHARED_LIBRARY)..."
    if "$ICLOUDPD_BIN" -d "$BACKUP_DIR" --username "$USERNAME" --until-found "$UNTIL_FOUND" --cookie-directory "$COOKIE_DIRECTORY" --library="$SHARED_LIBRARY" 2>&1 | tee "$tmpout"; then
        shared_new=$(count_new_downloads)
        log "Shared library backup completed successfully. New photos: $shared_new"
        summary+="Shared library: OK ($shared_new new)"
    else
        shared_new=$(count_new_downloads)
        log "ERROR: Shared library backup failed (exit code: ${PIPESTATUS[0]}). New photos before failure: $shared_new"
        summary+="Shared library: FAILED ($shared_new new)"
        failed=$((failed + 1))
    fi
    total_new=$((total_new + shared_new))
else
    log "Skipping shared library backup (SHARED_LIBRARY not set)."
fi

# --- Personal library backup ---
personal_new=0
log "Running personal library backup..."
if "$ICLOUDPD_BIN" -d "$BACKUP_DIR" --username "$USERNAME" --until-found "$UNTIL_FOUND" --cookie-directory "$COOKIE_DIRECTORY" 2>&1 | tee "$tmpout"; then
    personal_new=$(count_new_downloads)
    log "Personal library backup completed successfully. New photos: $personal_new"
    summary+=", Personal library: OK ($personal_new new)"
else
    personal_new=$(count_new_downloads)
    log "ERROR: Personal library backup failed (exit code: ${PIPESTATUS[0]}). New photos before failure: $personal_new"
    summary+=", Personal library: FAILED ($personal_new new)"
    failed=$((failed + 1))
fi
total_new=$((total_new + personal_new))

# --- Most recent photo date ---
latest_photo_date=$(find "$BACKUP_DIR" -mindepth 3 -maxdepth 3 -type d | sort -r | head -1 | grep -oP '\d{4}/\d{2}/\d{2}$' || true)
if [[ -n "$latest_photo_date" ]]; then
    latest_photo_date="${latest_photo_date//\//-}"
fi

# --- Summary ---
echo
log "===== Backup complete ====="
log "$summary"
log "Total new photos: $total_new"
log "Most recent photo: $latest_photo_date"
summary+=$'\n'"Total new photos: $total_new"
summary+=$'\n'"Most recent photo: $latest_photo_date"

if (( failed > 0 )); then
    hc_ping fail "$summary"
else
    hc_ping "" "$summary"
fi
