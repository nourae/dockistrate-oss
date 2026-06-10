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

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_enable_mtls_fail.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
UPDATE_MARKER="$TMP_ROOT/update_called"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls"
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS

function log_msg() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() { : >"$UPDATE_MARKER"; }
function _ensure_tls_permissions() { :; }
function _generate_backend_ca() {
  local mtls_dir="${1:-}"
  mkdir -p "$mtls_dir"
  printf 'new-ca\n' >"${mtls_dir}/ca.crt"
  printf 'new-key\n' >"${mtls_dir}/ca.key"
}
function _generate_backend_crl() {
  echo "[Error] Forced CRL generation failure" >&2
  return 1
}

set +e
set +E
output="$(
  (enable_backend_mtls example.com) 2>&1
)"
status=$?
set -E
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] enable_backend_mtls succeeded unexpectedly." >&2
  exit 1
fi

if [ -e "$BACKEND_MTLS_FILE" ] || [ -L "$BACKEND_MTLS_FILE" ]; then
  if ! csv_require_header "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER"; then
    echo "[Error] Backend mTLS mapping file was not restored cleanly after rollback." >&2
    exit 1
  fi
  if [ "$(csv_data_row_count "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER")" -ne 0 ]; then
    echo "[Error] Backend mTLS mapping rows persisted after rollback." >&2
    exit 1
  fi
fi

if [ -e "${CERTS_DIR}/mtls/example.com" ] || [ -L "${CERTS_DIR}/mtls/example.com" ]; then
  echo "[Error] New mTLS directory persisted after rollback." >&2
  exit 1
fi

if [ -e "$UPDATE_MARKER" ] || [ -L "$UPDATE_MARKER" ]; then
  echo "[Error] enable_backend_mtls continued into update_nginx_config after helper failure." >&2
  exit 1
fi

if ! grep -Fq "Rolled back" <<<"$output"; then
  echo "[Error] Expected rollback message missing for enable-backend-mtls failure." >&2
  echo "$output" >&2
  exit 1
fi

echo "enable-backend-mtls rollback removes new state on failure."
