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
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
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
# Runtime rollback reloads the fixture settings before running recovery hooks.
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"

cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_MTLS

mtls_dir="${CERTS_DIR}/mtls/example.com"
_generate_backend_ca "$mtls_dir" example.com >/dev/null 2>&1
_init_backend_mtls_state "$mtls_dir" fresh
_issue_backend_client_cert "$mtls_dir" client1 >/dev/null 2>&1
_generate_backend_crl "$mtls_dir" >/dev/null 2>&1
for file in client1.crt client1.key ca.crl index.txt serial crlnumber; do cp "$mtls_dir/$file" "$TMP_ROOT/original-$file"; done

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
  if [ "${1:-}" = req ]; then
    : >"$TMP_ROOT/issuance-reached"
    return 1
  fi
  command openssl "$@"
}

set +e
set +E
output="$(
  (replace_backend_client_cert example.com client1) 2>&1
)"
status=$?
set -E
set -e

if [ ! -f "$TMP_ROOT/issuance-reached" ]; then
  echo "[Error] Replacement did not reach injected issuance failure: $output" >&2
  exit 1
fi
for file in index.txt serial crlnumber; do
  if ! cmp -s "$mtls_dir/$file" "$TMP_ROOT/original-$file"; then
    echo "[Error] Authority history changed after replacement rollback: $file" >&2
    exit 1
  fi
done

if [ "$status" -eq 0 ]; then
  echo "[Error] replace_backend_client_cert succeeded unexpectedly." >&2
  exit 1
fi

if ! cmp -s "$mtls_dir/client1.crt" "$TMP_ROOT/original-client1.crt"; then
  echo "[Error] Original client certificate was not restored after rollback." >&2
  exit 1
fi

if ! cmp -s "$mtls_dir/client1.key" "$TMP_ROOT/original-client1.key"; then
  echo "[Error] Original client key was not restored after rollback." >&2
  exit 1
fi

if ! cmp -s "$mtls_dir/ca.crl" "$TMP_ROOT/original-ca.crl"; then
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
