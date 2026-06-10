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

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_enable_mtls_txn_start_fail.XXXXXX")")"
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

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls"
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS

unexpected_write_marker="${TMP_ROOT}/unexpected-write"

function log_msg() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() { :; }
function _ensure_tls_permissions() { :; }
function begin_transaction() { return 1; }
function _generate_backend_ca() {
  printf 'called\n' >"$unexpected_write_marker"
}

set +e
output="$(
  (enable_backend_mtls example.com) 2>&1
)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] enable_backend_mtls succeeded unexpectedly when begin_transaction failed." >&2
  exit 1
fi

if [ -e "$BACKEND_MTLS_FILE" ] || [ -L "$BACKEND_MTLS_FILE" ]; then
  echo "[Error] Backend mTLS mapping file was created after begin_transaction failed." >&2
  exit 1
fi

if [ -e "${CERTS_DIR}/mtls/example.com" ] || [ -L "${CERTS_DIR}/mtls/example.com" ]; then
  echo "[Error] Backend mTLS directory was created after begin_transaction failed." >&2
  exit 1
fi

if [ -e "$unexpected_write_marker" ] || [ -L "$unexpected_write_marker" ]; then
  echo "[Error] enable_backend_mtls performed writes after begin_transaction failed." >&2
  exit 1
fi

if grep -Fq "Rolled back" <<<"$output"; then
  echo "[Error] Unexpected rollback message when begin_transaction failed before transaction start." >&2
  echo "$output" >&2
  exit 1
fi

echo "enable-backend-mtls exits cleanly when transaction start fails."
