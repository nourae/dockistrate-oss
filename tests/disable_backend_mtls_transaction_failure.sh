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
source "$ROOT_DIR/lib/mtls.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_disable_mtls_fail.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
UPDATE_MARKER="$TMP_ROOT/update_called"
NGINX_HTTP_CONF_DIR="$CONFIG_DIR/nginx_conf/conf.d"
EXISTING_CONF_FILE="$NGINX_HTTP_CONF_DIR/example.conf"
GENERATED_CONF_FILE="$NGINX_HTTP_CONF_DIR/generated.conf"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$NGINX_HTTP_CONF_DIR"

cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_MTLS
printf 'stable-config\n' >"$EXISTING_CONF_FILE"

function log_msg() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() {
  : >"$UPDATE_MARKER"
  printf 'mutated-config\n' >"$EXISTING_CONF_FILE"
  printf 'generated-during-update\n' >"$GENERATED_CONF_FILE"
  return 1
}

set +e
set +E
output="$(
  (disable_backend_mtls example.com) 2>&1
)"
status=$?
set -E
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] disable_backend_mtls succeeded unexpectedly." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_MTLS_FILE" <(cat <<EOF_EXPECTED
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_EXPECTED
); then
  echo "[Error] mTLS mapping changed after disable-backend-mtls rollback." >&2
  exit 1
fi

if [ ! -e "$UPDATE_MARKER" ] && [ ! -L "$UPDATE_MARKER" ]; then
  echo "[Error] disable_backend_mtls did not reach the forced update_nginx_config failure." >&2
  exit 1
fi

if [ "$(cat "$EXISTING_CONF_FILE")" != "stable-config" ]; then
  echo "[Error] disable_backend_mtls did not roll back mutated nginx config content." >&2
  exit 1
fi

if [ -e "$GENERATED_CONF_FILE" ] || [ -L "$GENERATED_CONF_FILE" ]; then
  echo "[Error] disable_backend_mtls did not remove generated nginx config during rollback." >&2
  exit 1
fi

if ! grep -Fq "Rolled back" <<<"$output"; then
  echo "[Error] Expected rollback message missing for disable-backend-mtls failure." >&2
  echo "$output" >&2
  exit 1
fi

if grep -Fq "Disabled mTLS for example.com" <<<"$output"; then
  echo "[Error] disable_backend_mtls reported success after helper failure." >&2
  echo "$output" >&2
  exit 1
fi

echo "disable-backend-mtls reports failure cleanly when nginx update fails."
