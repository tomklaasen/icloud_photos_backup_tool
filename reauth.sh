#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"

COOKIE_DIRECTORY="${COOKIE_DIRECTORY:-$HOME/.pyicloud}"

"$ICLOUDPD_BIN" --auth-only --username "$USERNAME" --cookie-directory "$COOKIE_DIRECTORY"
