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
source "$ROOT_DIR/lib/tokens.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_server_tokens_txn_start_fail.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$NGINX_HTTP_CONF_DIR"

legacy_tokens_conf="$NGINX_HTTP_CONF_DIR/server_tokens.conf"
cat >"$legacy_tokens_conf" <<'EOF_CONF'
server_tokens on;
EOF_CONF

unexpected_write_marker="$TMP_ROOT/unexpected-write"

function begin_transaction() { return 1; }
function nginx_directives_set_managed_owned() {
  printf 'called\n' >"$unexpected_write_marker"
}
function safe_rm_f() {
  printf 'called\n' >"$unexpected_write_marker"
}
function create_backup() {
  printf 'called\n' >"$unexpected_write_marker"
}
function update_nginx_config() {
  printf 'called\n' >"$unexpected_write_marker"
}

set +e
output="$(
  (control_server_tokens off) 2>&1
)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] control_server_tokens succeeded unexpectedly when begin_transaction failed." >&2
  exit 1
fi

if [ -e "$unexpected_write_marker" ] || [ -L "$unexpected_write_marker" ]; then
  echo "[Error] control_server_tokens performed writes after begin_transaction failed." >&2
  exit 1
fi

if [ ! -f "$legacy_tokens_conf" ]; then
  echo "[Error] legacy server_tokens.conf should remain untouched when begin_transaction fails." >&2
  exit 1
fi

if [ -e "$CONFIG_DIR/nginx_directives.csv" ] || [ -L "$CONFIG_DIR/nginx_directives.csv" ]; then
  echo "[Error] nginx_directives.csv should not be created when begin_transaction fails." >&2
  exit 1
fi

if grep -Fq "Rolled back" <<<"$output"; then
  echo "[Error] Unexpected rollback message when begin_transaction failed before transaction start." >&2
  echo "$output" >&2
  exit 1
fi

echo "control-server-tokens exits cleanly when transaction start fails."
