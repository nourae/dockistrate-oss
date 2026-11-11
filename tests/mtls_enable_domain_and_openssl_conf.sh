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

MTLS_DIR="$CERTS_DIR/mtls/example.com"

function assert_complete_mtls_directives() {
  local directives="${1:-}" label="${2:-mTLS directives}"
  if [ "$(grep -Fxc '    ssl_client_certificate /etc/letsencrypt/mtls/example.com/ca.crt;' <<<"$directives")" -ne 1 ] ||
    [ "$(grep -Fxc '    ssl_crl /etc/letsencrypt/mtls/example.com/ca.crl;' <<<"$directives")" -ne 1 ] ||
    [ "$(grep -Fxc '    ssl_verify_client on;' <<<"$directives")" -ne 1 ]; then
    echo "[Error] ${label} did not emit the complete validated directive set." >&2
    echo "$directives" >&2
    exit 1
  fi
}

function expect_mtls_directives_failure() {
  local label="${1:-mTLS render}" expected="${2:-}"
  local output_file="$TMP_ROOT/mtls-directives.out" error_file="$TMP_ROOT/mtls-directives.err"
  local status=0

  : >"$output_file"
  : >"$error_file"
  set +e
  _backend_mtls_directives example.com >"$output_file" 2>"$error_file"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "[Error] ${label} unexpectedly succeeded." >&2
    exit 1
  fi
  if [ -s "$output_file" ]; then
    echo "[Error] ${label} emitted partial mTLS directives before failing." >&2
    cat "$output_file" >&2
    exit 1
  fi
  if [ -n "$expected" ] && ! grep -Fq "$expected" "$error_file"; then
    echo "[Error] ${label} did not report the expected diagnostic: ${expected}" >&2
    cat "$error_file" >&2
    exit 1
  fi
}

generator_marker="$TMP_ROOT/crl-generator-called"
function _generate_backend_crl() {
  : >"$generator_marker"
  return 1
}
directives="$(_backend_mtls_directives example.com)"
assert_complete_mtls_directives "$directives" "existing CRL render"
if [ -e "$generator_marker" ]; then
  echo "[Error] Existing regular mTLS CRL unexpectedly triggered regeneration." >&2
  exit 1
fi

rm -f "$MTLS_DIR/ca.crl"
unset -f _generate_backend_crl
expect_mtls_directives_failure "missing CRL without generator" "CRL generation is unavailable"
# shellcheck source=../lib/mtls/_generate_backend_crl.sh
source "$ROOT_DIR/lib/mtls/_generate_backend_crl.sh"

function _generate_backend_crl() {
  printf 'unexpected generator stdout\n'
  echo "forced CRL generation failure" >&2
  return 1
}
expect_mtls_directives_failure "failed CRL generation" "Failed to generate required mTLS CRL"

function _generate_backend_crl() { return 0; }
expect_mtls_directives_failure "false-success CRL generation" "did not create a safe regular mTLS CRL"

outside_crl="$TMP_ROOT/outside.crl"
printf 'outside crl\n' >"$outside_crl"
ln -s "$outside_crl" "$MTLS_DIR/ca.crl"
expect_mtls_directives_failure "symlinked CRL" "must be a non-symlink regular file"
rm -f "$MTLS_DIR/ca.crl"

mkfifo "$MTLS_DIR/ca.crl"
expect_mtls_directives_failure "special-file CRL" "must be a non-symlink regular file"
rm -f "$MTLS_DIR/ca.crl"

function _generate_backend_crl() {
  local mtls_dir="${1:-}"
  printf 'regenerated crl\n' >"${mtls_dir}/ca.crl"
}
directives="$(_backend_mtls_directives example.com)"
assert_complete_mtls_directives "$directives" "regenerated CRL render"
if [ "$(cat "$MTLS_DIR/ca.crl")" != "regenerated crl" ]; then
  echo "[Error] Missing mTLS CRL was not regenerated before rendering." >&2
  exit 1
fi
# shellcheck source=../lib/mtls/_generate_backend_crl.sh
source "$ROOT_DIR/lib/mtls/_generate_backend_crl.sh"

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
