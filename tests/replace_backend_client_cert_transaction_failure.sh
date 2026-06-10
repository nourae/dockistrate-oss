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

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_replace_client_fail.XXXXXX")")"
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

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls/example.com"

cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_MTLS

mtls_dir="${CERTS_DIR}/mtls/example.com"
printf 'old-client\n' >"${mtls_dir}/client1.crt"
printf 'old-client-key\n' >"${mtls_dir}/client1.key"
printf 'old-crl\n' >"${mtls_dir}/ca.crl"

function log_msg() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() {
  if [ "${SKIP_UPDATE_NGINX_CONFIG:-}" = "true" ]; then
    return 0
  fi
  : >"$UPDATE_MARKER"
}
function _ensure_tls_permissions() { :; }
function openssl() {
  local cmd="${1:-}" out=""
  shift || true
  case "$cmd" in
    ca)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -revoke)
            return 0
            ;;
          -out)
            shift
            out="${1:-}"
            ;;
        esac
        shift || true
      done
      [ -n "$out" ] && printf 'new-crl\n' >"$out"
      return 0
      ;;
    req)
      return 1
      ;;
  esac
  command openssl "$cmd" "$@"
}

set +e
set +E
output="$(
  (replace_backend_client_cert example.com client1) 2>&1
)"
status=$?
set -E
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] replace_backend_client_cert succeeded unexpectedly." >&2
  exit 1
fi

if [ "$(cat "${mtls_dir}/client1.crt")" != "old-client" ]; then
  echo "[Error] Original client certificate was not restored after rollback." >&2
  exit 1
fi

if [ "$(cat "${mtls_dir}/client1.key")" != "old-client-key" ]; then
  echo "[Error] Original client key was not restored after rollback." >&2
  exit 1
fi

if [ "$(cat "${mtls_dir}/ca.crl")" != "old-crl" ]; then
  echo "[Error] Original CRL was not restored after rollback." >&2
  exit 1
fi

if [ -e "$UPDATE_MARKER" ] || [ -L "$UPDATE_MARKER" ]; then
  echo "[Error] replace_backend_client_cert continued into update_nginx_config after helper failure." >&2
  exit 1
fi

if ! grep -Fq "Rolled back" <<<"$output"; then
  echo "[Error] Expected rollback message missing for replace-backend-client-cert failure." >&2
  echo "$output" >&2
  exit 1
fi

echo "replace-backend-client-cert rollback restores original client material."
