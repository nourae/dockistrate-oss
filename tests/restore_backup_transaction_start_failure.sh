#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_restore_txn_start_fail.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONTAINER_NAME="nginx-proxy"
NGINX_IMAGE="nginx:1.28.1"
SKIP_DOCKER_CHECKS="true"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR"

cat >"$CONFIG_DIR/marker.txt" <<'EOF_MARKER'
old
EOF_MARKER

BACKUP_SOURCE="$TMP_ROOT/backup_snapshot"
mkdir -p "$BACKUP_SOURCE/config"
cat >"$BACKUP_SOURCE/config/marker.txt" <<'EOF_NEW_MARKER'
new
EOF_NEW_MARKER
cat >"$BACKUP_SOURCE/config/new_only.txt" <<'EOF_NEW_FILE'
new-file
EOF_NEW_FILE

unexpected_write_marker="$TMP_ROOT/unexpected-write"

function confirm_prompt() { return 0; }
function begin_transaction() { return 1; }
function fix_permissions() {
  printf 'called\n' >"$unexpected_write_marker"
}
function update_nginx_config() {
  printf 'called\n' >"$unexpected_write_marker"
}
function recreate_nginx_container() {
  printf 'called\n' >"$unexpected_write_marker"
}
function check_config() {
  printf 'called\n' >"$unexpected_write_marker"
}

set +e
output="$(
  (restore_backup "$BACKUP_SOURCE") 2>&1
)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] restore_backup succeeded unexpectedly when begin_transaction failed." >&2
  exit 1
fi

if [ -e "$unexpected_write_marker" ] || [ -L "$unexpected_write_marker" ]; then
  echo "[Error] restore_backup performed writes after begin_transaction failed." >&2
  exit 1
fi

if ! grep -qx 'old' "$CONFIG_DIR/marker.txt"; then
  echo "[Error] Existing config should remain unchanged when begin_transaction fails." >&2
  exit 1
fi

if [ -e "$CONFIG_DIR/new_only.txt" ] || [ -L "$CONFIG_DIR/new_only.txt" ]; then
  echo "[Error] Backup contents should not be copied when begin_transaction fails." >&2
  exit 1
fi

if grep -Fq "Rolled back" <<<"$output"; then
  echo "[Error] Unexpected rollback message when begin_transaction failed before transaction start." >&2
  echo "$output" >&2
  exit 1
fi

echo "restore-backup exits cleanly when transaction start fails."
