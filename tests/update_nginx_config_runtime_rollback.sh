#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_update_nginx_rollback.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CAPTURE_DIR="$STATE_DIR/pcaps"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"
SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
TRACE_FILE="$TMP_ROOT/trace.log"
NGINX_CONTAINER_NAME="nginx-proxy"
NGINX_IMAGE="nginx:1.28.1"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_equals() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" != "$actual" ]; then
    fail_test "$message (expected '$expected', got '$actual')"
  fi
}

function assert_path_under_state() {
  local path="$1" label="$2"
  case "$path" in
    "$STATE_DIR"/*) ;;
    *) fail_test "$label should stay under test STATE_DIR (got '$path')" ;;
  esac
}

function assert_trace_contains() {
  local needle="$1"
  grep -qx "$needle" "$TRACE_FILE" || fail_test "Expected trace line '$needle'"
}

function count_trace() {
  local needle="$1"
  awk -v needle="$needle" '$0 == needle { c++ } END { print c + 0 }' "$TRACE_FILE"
}

function _trace_append() {
  printf '%s\n' "$1" >>"$TRACE_FILE"
}

function log_msg() { :; }

function capture_docker_logs() {
  _trace_append "capture_docker_logs"
}

function build_security_rules_inc() { :; }
function refresh_backend_networks() { :; }
function refresh_backend_ips() { :; }
function _build_header_files() { :; }
function list_domain_aliases() { :; }
function get_backend_http_version() { printf '%s\n' "http1"; }
function _backend_header_identity_directives() { :; }
function _render_backend_upstream_for_domain() { printf '%s\n' "10.0.0.5:8000"; }
function get_backend_client_ip_header() { :; }
function get_backend_proxy_ip_header() { :; }
function get_proxy_http_version() { printf '%s\n' "1.1"; }

function create_nginx_config() {
  mkdir -p "$NGINX_CONFIG_DIR"
  cat >"${NGINX_CONFIG_DIR}/nginx.conf" <<'EOF_NGINX'
worker_processes  1;
events {}
http {}
EOF_NGINX
}

function fix_default_config() {
  _trace_append "fix_default_config"
  printf 'new\n' >"$CONFIG_DIR/marker.txt"
}

function get_all_mapped_port_bindings() {
  printf '%s\n' "${STUB_NEW_BINDINGS:-}"
}

function container_exists() {
  _trace_append "container_exists"
  [ "${STUB_CONTAINER_EXISTS:-false}" = "true" ]
}

function container_running() {
  _trace_append "container_running"
  [ "${STUB_CONTAINER_RUNNING:-false}" = "true" ]
}

function container_published_port_bindings() {
  local binding=""
  for binding in ${STUB_PUBLISHED_BINDINGS:-}; do
    printf '%s\n' "$binding"
  done
}

function remove_container_and_anonymous_volumes() {
  _trace_append "remove_container_and_anonymous_volumes"
  STUB_CONTAINER_EXISTS="false"
  STUB_CONTAINER_RUNNING="false"
  STUB_PUBLISHED_BINDINGS=""
}

function recreate_nginx_container() {
  local image="${1:-}" bindings="" running_after="true"
  RECREATE_CALL_COUNT=$((RECREATE_CALL_COUNT + 1))
  if [ "$#" -ge 2 ]; then
    bindings="${2:-}"
  else
    bindings="${STUB_NEW_BINDINGS:-${STUB_PUBLISHED_BINDINGS:-}}"
  fi
  case "$RECREATE_CALL_COUNT" in
    1) running_after="${STUB_RECREATE_RUNNING_AFTER_CALL_1:-true}" ;;
    2) running_after="${STUB_RECREATE_RUNNING_AFTER_CALL_2:-true}" ;;
    *) running_after="${STUB_RECREATE_RUNNING_AFTER_DEFAULT:-true}" ;;
  esac

  _trace_append "recreate_nginx_container"
  _trace_append "recreate_nginx_container:${RECREATE_CALL_COUNT}:${image}:${bindings}"
  if declare -F _nginx_mark_runtime_rollback_needed >/dev/null 2>&1; then
    _nginx_mark_runtime_rollback_needed
  fi
  STUB_CONTAINER_EXISTS="false"
  STUB_CONTAINER_RUNNING="false"
  STUB_PUBLISHED_BINDINGS=""

  if [ "${STUB_RECREATE_FAIL_ON_CALL:-0}" = "$RECREATE_CALL_COUNT" ]; then
    return 1
  fi

  STUB_CONTAINER_EXISTS="true"
  STUB_CONTAINER_RUNNING="$running_after"
  STUB_PUBLISHED_BINDINGS="$bindings"
}

function add_nginx_networks() {
  _trace_append "add_nginx_networks"
}

function remove_unused_nginx_networks() {
  _trace_append "remove_unused_nginx_networks"
}

function reload_nginx_if_running() {
  _trace_append "reload_nginx_if_running"
  return 0
}

function docker() {
  local subcommand="${1:-}"
  shift || true

  case "$subcommand" in
    inspect)
      if [ "${1:-}" = "-f" ] && [ -n "${2:-}" ]; then
        case "${2:-}" in
          *".Config.Labels"*)
            case "${2:-}" in
              *"com.dockistrate.managed"*) printf 'true\n' ;;
              *"com.dockistrate.role"*) printf 'proxy\n' ;;
              *"com.dockistrate.state-dir"*) printf '%s\n' "$STATE_DIR" ;;
            esac
            return 0
            ;;
          *".Mounts"*)
            cat <<EOF
${NGINX_CONFIG_DIR}|${NGINX_CONTAINER_CONF_ROOT}|false
${CERTS_DIR}|/etc/letsencrypt|false
${ACME_WEBROOT_DIR}|/var/www/certbot|false
EOF
            return 0
            ;;
        esac
      fi
      if [ "${1:-}" = "-f" ] && [ "${2:-}" = "{{.Config.Image}}" ]; then
        printf '%s\n' "${STUB_RUNNING_IMAGE:-$NGINX_IMAGE}"
        return 0
      fi
      return 0
      ;;
    stop)
      _trace_append "docker_stop"
      STUB_CONTAINER_RUNNING="false"
      return 0
      ;;
    exec)
      _trace_append "docker_exec:$*"
      [ "${STUB_SECURITY_READY_FAIL:-false}" != "true" ]
      return $?
      ;;
    *)
      return 0
      ;;
  esac
}

function reset_update_state() {
  rm -rf "$STATE_DIR"
  assert_path_under_state "$CERTS_DIR" "CERTS_DIR"
  assert_path_under_state "$ACME_WEBROOT_DIR" "ACME_WEBROOT_DIR"
  assert_path_under_state "$CAPTURE_DIR" "CAPTURE_DIR"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
    "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR" "$PATH_HEADER_DIR" \
    "$CERTS_DIR" "$ACME_WEBROOT_DIR" "$CAPTURE_DIR"
  : >"$TRACE_FILE"

  create_nginx_config
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"
  printf 'old\n' >"$CONFIG_DIR/marker.txt"

  STUB_CONTAINER_EXISTS="true"
  STUB_CONTAINER_RUNNING="true"
  STUB_PUBLISHED_BINDINGS="80/tcp"
  STUB_NEW_BINDINGS="81/tcp"
  STUB_RUNNING_IMAGE="$NGINX_IMAGE"
  STUB_RECREATE_FAIL_ON_CALL="0"
  STUB_RECREATE_RUNNING_AFTER_CALL_1="true"
  STUB_RECREATE_RUNNING_AFTER_CALL_2="true"
  STUB_RECREATE_RUNNING_AFTER_DEFAULT="true"
  STUB_SECURITY_READY_FAIL="false"
  SKIP_DOCKER_CHECKS="false"
  RECREATE_CALL_COUNT=0
  unset DOCKISTRATE_FORCE_NGINX_RECREATE
  unset DOCKISTRATE_SECURITY_NGINX_READY_CHECK
  unset DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE
  unset DOCKISTRATE_SECURITY_NGINX_READY_ATTEMPTS
}

# Scenario A: unsafe persisted mTLS state fails closed before config is rendered without client auth.
reset_update_state
mkdir -p "$CERTS_DIR/letsencrypt/live/example.com_443"
outside_mtls_dir="$TMP_ROOT/outside-mtls"
mkdir -p "$outside_mtls_dir"
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.com,,,,,443,8000,https,letsencrypt/live/example.com_443,no,off,,off,auto,,,,,,
EOF_PORTS
cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
example.com,$outside_mtls_dir
EOF_MTLS
set +e
(update_nginx_config) >/dev/null 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "update_nginx_config should fail when persisted mTLS state points outside CERTS_DIR/mtls"
fi
assert_equals "old" "$(cat "$CONFIG_DIR/marker.txt")" "config rollback should restore the previous marker after mTLS render failure"
assert_equals "0" "$(count_trace "recreate_nginx_container")" "mTLS render failure should happen before nginx runtime recreation"

# Scenario B: recreate failure restores the previous nginx runtime.
reset_update_state
STUB_RECREATE_FAIL_ON_CALL="1"
set +e
(update_nginx_config)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "update_nginx_config should fail when recreate_nginx_container fails"
fi
assert_equals "old" "$(cat "$CONFIG_DIR/marker.txt")" "config rollback should restore the previous marker"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "rollback should attempt a second recreate after recreate failure"
assert_trace_contains "recreate_nginx_container:2:${NGINX_IMAGE}:80/tcp"

# Scenario C: post-recreate running check failure restores the previous nginx runtime.
reset_update_state
STUB_RECREATE_RUNNING_AFTER_CALL_1="false"
set +e
(update_nginx_config)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "update_nginx_config should fail when recreated nginx is not running"
fi
assert_equals "old" "$(cat "$CONFIG_DIR/marker.txt")" "config rollback should restore the previous marker after failed start"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "rollback should recreate nginx again after failed start"
assert_equals "1" "$(count_trace "remove_container_and_anonymous_volumes")" "rollback should remove the failed recreated container"
assert_trace_contains "recreate_nginx_container:2:${NGINX_IMAGE}:80/tcp"

# Scenario D: security readiness failure after forced recreate restores previous nginx runtime.
reset_update_state
DOCKISTRATE_FORCE_NGINX_RECREATE=true
DOCKISTRATE_SECURITY_NGINX_READY_CHECK=true
DOCKISTRATE_SECURITY_NGINX_READY_ATTEMPTS=1
STUB_SECURITY_READY_FAIL="true"
set +e
(update_nginx_config)
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "update_nginx_config should fail when security readiness check fails"
fi
assert_equals "old" "$(cat "$CONFIG_DIR/marker.txt")" "config rollback should restore the previous marker after security readiness failure"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "security readiness rollback should recreate nginx again"
assert_equals "1" "$(count_trace "remove_container_and_anonymous_volumes")" "security readiness rollback should remove the failed recreated container"
assert_trace_contains "docker_exec:nginx-proxy nginx -t -c ${NGINX_CONTAINER_MAIN_CONF}"
assert_trace_contains "recreate_nginx_container:2:${NGINX_IMAGE}:80/tcp"

echo "update-nginx-config runtime rollback restores the previous nginx container state."
