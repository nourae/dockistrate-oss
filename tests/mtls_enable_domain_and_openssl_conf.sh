#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/mtls.sh
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck source=../lib/nginx/_backend_mtls_directives.sh
source "$ROOT_DIR/lib/nginx/_backend_mtls_directives.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls_enable.XXXXXX")")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
NGINX_CONTAINER_NAME="dockistrate-nginx"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls"
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"

function log_msg() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() { :; }
function _ensure_tls_permissions() { chmod 600 "$1"; }
function _generate_backend_ca() {
  local mtls_dir="${1:-}"
  mkdir -p "$mtls_dir"
  printf 'ca\n' >"${mtls_dir}/ca.crt"
  printf 'key\n' >"${mtls_dir}/ca.key"
}
function _generate_backend_crl() {
  local mtls_dir="${1:-}"
  printf 'crl\n' >"${mtls_dir}/ca.crl"
}

set +e
(enable_backend_mtls '../bad') >/dev/null 2>&1
bad_status=$?
(enable_backend_mtls unknown.example) >/dev/null 2>&1
unknown_status=$?
set -e

if [ "$bad_status" -eq 0 ]; then
  echo "[Error] enable_backend_mtls accepted an invalid domain." >&2
  exit 1
fi
if [ "$unknown_status" -eq 0 ]; then
  echo "[Error] enable_backend_mtls accepted an unknown domain." >&2
  exit 1
fi
if [ -d "$CERTS_DIR/mtls/unknown.example" ]; then
  echo "[Error] enable_backend_mtls created mTLS material for an unknown domain." >&2
  exit 1
fi

enable_backend_mtls example.com >/dev/null
OPENSSL_CONF="$CERTS_DIR/mtls/example.com/openssl.cnf"
if [ ! -f "$OPENSSL_CONF" ]; then
  echo "[Error] mTLS OpenSSL config was not written." >&2
  exit 1
fi
mode="$(stat -c '%a' "$OPENSSL_CONF" 2>/dev/null || stat -f '%Lp' "$OPENSSL_CONF")"
if [ "$mode" != "600" ]; then
  echo "[Error] mTLS OpenSSL config mode should be 600, got ${mode}." >&2
  exit 1
fi
if grep -Fq 'copy_extensions = copy' "$OPENSSL_CONF"; then
  echo "[Error] mTLS OpenSSL config should not copy CSR extensions." >&2
  exit 1
fi
if ! grep -Fq 'basicConstraints = CA:FALSE' "$OPENSSL_CONF"; then
  echo "[Error] mTLS OpenSSL config lost CA:FALSE client constraint." >&2
  exit 1
fi

OUTSIDE_DIR="$TMP_ROOT/outside"
mkdir -p "$OUTSIDE_DIR"
cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,$OUTSIDE_DIR
EOF_MTLS
if _backend_mtls_directives example.com >/dev/null 2>&1; then
  echo "[Error] Nginx mTLS render accepted a persisted mTLS directory outside CERTS_DIR/mtls." >&2
  exit 1
fi

echo "[tests] mtls_enable_domain_and_openssl_conf.sh: PASS"
