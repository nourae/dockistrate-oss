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
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/tls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/ports.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/http_version.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/clean_uninstall.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_remove_backend_mtls_missing.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SKIP_DOCKER_CHECKS=true
INTERACTIVE=false
ENABLE_AUTO_BACKUPS=false
ENABLE_BACKUP_COMPRESSION=false
BACKUP_RETENTION=0

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"
SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
SECURITY_RULES_DB="$SECURITY_RULES_FILE"
SECURITY_IP_RULES_DB="$SECURITY_IP_RULES_FILE"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

INJECT_MTLS_ON_BEGIN=false
BEGIN_TRANSACTION_INJECTION_MARKER=""

function transaction_is_active() { return 1; }
function begin_transaction() {
  if [ "$INJECT_MTLS_ON_BEGIN" = true ]; then
    mkdir -p "$CERTS_DIR/mtls/example.com"
    printf 'appeared after preflight\n' >"$CERTS_DIR/mtls/example.com/sentinel.txt"
    if [ -n "$BEGIN_TRANSACTION_INJECTION_MARKER" ]; then
      : >"$BEGIN_TRANSACTION_INJECTION_MARKER"
    fi
    INJECT_MTLS_ON_BEGIN=false
  fi
  return 0
}
function end_transaction_success() { return 0; }
function transaction_return_failure() { return 1; }
function update_nginx_config() { return 0; }
function create_backup() { return 0; }
function set_backend_docker_opts() { return 0; }
function _cleanup_runtime_stage_container_delete() { return 0; }
function _cleanup_runtime_finalize_staged_deletes() { return 0; }

function reset_fixture() {
  INJECT_MTLS_ON_BEGIN=false
  BEGIN_TRANSACTION_INJECTION_MARKER=""
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
    "$CERTS_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"

  cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
backend,other.test,10.0.0.6:8000,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"
}

function assert_lock_window_material_is_removed() {
  local command_name="${1:-}" output="" status=0
  local injection_marker="$TMP_ROOT/${command_name}-begin-injected"
  reset_fixture
  write_canonical_missing_root_state
  rm -f "$injection_marker"
  INJECT_MTLS_ON_BEGIN=true
  BEGIN_TRANSACTION_INJECTION_MARKER="$injection_marker"

  set +e
  output="$($command_name example.com 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "[Error] ${command_name} failed after canonical mTLS material appeared during transaction start." >&2
    echo "$output" >&2
    exit 1
  fi
  if [ ! -f "$injection_marker" ]; then
    echo "[Error] ${command_name} did not exercise the transaction-start injection." >&2
    exit 1
  fi
  if [ -e "$CERTS_DIR/mtls/example.com" ] || [ -L "$CERTS_DIR/mtls/example.com" ]; then
    echo "[Error] ${command_name} left mTLS material that appeared while acquiring the transaction lock." >&2
    exit 1
  fi
  if grep -Fq 'example.com,' "$BACKEND_MTLS_FILE"; then
    echo "[Error] ${command_name} did not remove the mTLS mapping after lock-window material appeared." >&2
    exit 1
  fi
}

function write_canonical_missing_root_state() {
  cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,$CERTS_DIR/mtls/example.com
other.test,$CERTS_DIR/mtls/other.test
EOF_MTLS
}

function assert_missing_root_cleanup_succeeds() {
  local command_name="${1:-}" output="" status=0
  reset_fixture
  write_canonical_missing_root_state

  if [ -e "$CERTS_DIR/mtls" ] || [ -L "$CERTS_DIR/mtls" ]; then
    echo "[Error] ${command_name} fixture unexpectedly created the mTLS root." >&2
    exit 1
  fi
  if validate_backend_mtls_state_for_render >/dev/null 2>&1; then
    echo "[Error] Strict render validation accepted a missing mTLS root." >&2
    exit 1
  fi
  if ! validate_backend_mtls_state_for_cleanup >/dev/null 2>&1; then
    echo "[Error] Cleanup validation rejected canonical stale mappings under a missing mTLS root." >&2
    exit 1
  fi

  set +e
  output="$($command_name example.com 2>&1)"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "[Error] ${command_name} rejected canonical stale mTLS state with a missing root." >&2
    echo "$output" >&2
    exit 1
  fi
  if [ -e "$CERTS_DIR/mtls" ] || [ -L "$CERTS_DIR/mtls" ]; then
    echo "[Error] ${command_name} recreated the missing mTLS root." >&2
    exit 1
  fi
  if grep -Fq 'example.com,' "$BACKEND_MTLS_FILE"; then
    echo "[Error] ${command_name} did not remove the stale mTLS mapping." >&2
    exit 1
  fi
  if ! grep -Fxq "other.test,$CERTS_DIR/mtls/other.test" "$BACKEND_MTLS_FILE"; then
    echo "[Error] ${command_name} changed the unrelated canonical mTLS mapping." >&2
    exit 1
  fi
  if grep -Fq 'backend,example.com,' "$BACKEND_PORTS_FILE"; then
    echo "[Error] ${command_name} did not remove the backend state." >&2
    exit 1
  fi
}

function assert_invalid_missing_root_state_is_atomic() {
  local command_name="${1:-}" output="" status=0 outside_dir="$TMP_ROOT/protected-${1:-unknown}"
  reset_fixture
  mkdir -p "$outside_dir"
  printf 'keep\n' >"$outside_dir/sentinel.txt"
  cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,$CERTS_DIR/mtls/example.com
other.test,$outside_dir
EOF_MTLS
  cp "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"
  cp "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"

  set +e
  output="$($command_name example.com 2>&1)"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "[Error] ${command_name} ignored an unsafe persisted mapping while the mTLS root was missing." >&2
    exit 1
  fi
  if ! grep -Fq 'persisted mTLS owner mappings are invalid' <<<"$output"; then
    echo "[Error] ${command_name} did not report invalid persisted mTLS ownership." >&2
    echo "$output" >&2
    exit 1
  fi
  if ! cmp -s "$BACKEND_PORTS_FILE" "$BACKEND_PORTS_FILE.orig"; then
    echo "[Error] ${command_name} changed backend state after rejecting unsafe missing-root state." >&2
    exit 1
  fi
  if ! cmp -s "$BACKEND_MTLS_FILE" "$BACKEND_MTLS_FILE.orig"; then
    echo "[Error] ${command_name} changed mTLS state after rejecting unsafe missing-root state." >&2
    exit 1
  fi
  if [ ! -f "$outside_dir/sentinel.txt" ]; then
    echo "[Error] ${command_name} removed a protected outside-root path." >&2
    exit 1
  fi
  if [ -e "$CERTS_DIR/mtls" ] || [ -L "$CERTS_DIR/mtls" ]; then
    echo "[Error] ${command_name} created an mTLS root while rejecting invalid state." >&2
    exit 1
  fi
}

for cleanup_command in remove_backend clean_all; do
  assert_missing_root_cleanup_succeeds "$cleanup_command"
  assert_lock_window_material_is_removed "$cleanup_command"
  assert_invalid_missing_root_state_is_atomic "$cleanup_command"
done

printf 'Backend cleanup removes canonical stale mTLS mappings without recreating a missing root and rejects unsafe state atomically.\n'
