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

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_add_client_fail.XXXXXX")")"
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
CRL_MARKER="$TMP_ROOT/crl_called"
UPDATE_MARKER="$TMP_ROOT/update_called"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls/example.com"

cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_MTLS

mtls_dir="${CERTS_DIR}/mtls/example.com"

function log_msg() { :; }
function capture_docker_logs() { :; }
function _issue_backend_client_cert() {
  echo "[Error] Forced client issuance failure" >&2
  return 1
}
function _generate_backend_crl() { : >"$CRL_MARKER"; }
function update_nginx_config() { : >"$UPDATE_MARKER"; }

set +e
set +E
output="$(
  (add_backend_client_cert example.com client1) 2>&1
)"
status=$?
set -E
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] add_backend_client_cert succeeded unexpectedly." >&2
  exit 1
fi

if [ -e "${mtls_dir}/client1.crt" ] || [ -L "${mtls_dir}/client1.crt" ]; then
  echo "[Error] Client certificate was created despite helper failure." >&2
  exit 1
fi

if [ -e "${mtls_dir}/client1.key" ] || [ -L "${mtls_dir}/client1.key" ]; then
  echo "[Error] Client key was created despite helper failure." >&2
  exit 1
fi

if [ -e "$CRL_MARKER" ] || [ -L "$CRL_MARKER" ]; then
  echo "[Error] add_backend_client_cert continued into CRL generation after helper failure." >&2
  exit 1
fi

if [ -e "$UPDATE_MARKER" ] || [ -L "$UPDATE_MARKER" ]; then
  echo "[Error] add_backend_client_cert continued into update_nginx_config after helper failure." >&2
  exit 1
fi

if ! cmp -s "$BACKEND_MTLS_FILE" <(cat <<EOF_EXPECTED
domain,mtls_directory
example.com,${CERTS_DIR}/mtls/example.com
EOF_EXPECTED
); then
  echo "[Error] mTLS mapping changed after add-backend-client-cert rollback." >&2
  exit 1
fi

if ! grep -Fq "Rolled back" <<<"$output"; then
  echo "[Error] Expected rollback message missing for add-backend-client-cert failure." >&2
  echo "$output" >&2
  exit 1
fi

echo "add-backend-client-cert aborts before CRL/update paths when issuance fails."
