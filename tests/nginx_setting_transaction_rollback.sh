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
source "$ROOT_DIR/lib/global_settings.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_nginx_setting_txn.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
TRACE_FILE="$TMP_ROOT/trace.log"
NGINX_CONTAINER_NAME="nginx-proxy"
NGINX_IMAGE="nginx:1.28.1"
NGINX_PULL_MODE="if-missing"
NGINX_DOCKER_OPTS=""
DEFAULT_NETWORK="dockistrate-net"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_same_file() {
  local left="$1" right="$2" message="$3"
  cmp -s "$left" "$right" || fail_test "$message"
}

function assert_equals() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" != "$actual" ]; then
    fail_test "$message (expected '$expected', got '$actual')"
  fi
}

function assert_trace_contains() {
  local needle="$1"
  grep -qx "$needle" "$TRACE_FILE" || fail_test "Expected trace line '$needle'"
}

function count_trace() {
  local needle="$1"
  awk -v key="$needle" '$0 == key { count++ } END { print count + 0 }' "$TRACE_FILE"
}

function _trace_append() {
  printf '%s\n' "$1" >>"$TRACE_FILE"
}

function assert_nginx_runtime_rollback_cleared() {
  local message="${1:-Nginx runtime rollback state should be cleared}"
  [ -z "${NGINX_RUNTIME_ROLLBACK_DEPTH:-}" ] || fail_test "${message}: NGINX_RUNTIME_ROLLBACK_DEPTH still set"
  [ -z "${NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED:-}" ] || fail_test "${message}: NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED still set"
  [ -z "${NGINX_RUNTIME_ROLLBACK_WAS_RUNNING:-}" ] || fail_test "${message}: NGINX_RUNTIME_ROLLBACK_WAS_RUNNING still set"
  [ -z "${NGINX_RUNTIME_ROLLBACK_IMAGE:-}" ] || fail_test "${message}: NGINX_RUNTIME_ROLLBACK_IMAGE still set"
  [ -z "${NGINX_RUNTIME_ROLLBACK_BINDINGS:-}" ] || fail_test "${message}: NGINX_RUNTIME_ROLLBACK_BINDINGS still set"
  [ -z "${NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED:-}" ] || fail_test "${message}: NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED still set"
  [ -z "${ROLLBACK_PRE_HOOK:-}" ] || fail_test "${message}: ROLLBACK_PRE_HOOK still set"
}

function capture_docker_logs() { :; }
function log_msg() { :; }
function add_nginx_networks() { :; }
function remove_unused_nginx_networks() { :; }
function is_valid_image_ref() { return 0; }
function normalize_nginx_image() { printf '%s\n' "${1:-}"; }
function image_uses_latest_tag() { return 1; }
function normalize_docker_opts_for_storage() { printf '%s\n' "${1:-}"; }
function create_nginx_config() {
  mkdir -p "$NGINX_CONFIG_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
  cat >"$NGINX_CONFIG_DIR/nginx.conf" <<'EOF_NGINX'
worker_processes  1;
events {}
http {}
EOF_NGINX
}
function update_nginx_config() {
  _trace_append "update_nginx_config"
  [ "${STUB_UPDATE_FAIL:-false}" != "true" ]
}
function container_exists() {
  [ "${STUB_CONTAINER_EXISTS:-false}" = "true" ]
}
function container_running() {
  [ "${STUB_CONTAINER_RUNNING:-false}" = "true" ]
}
function container_published_port_bindings() {
  local binding=""
  for binding in ${STUB_PUBLISHED_BINDINGS:-}; do
    printf '%s\n' "$binding"
  done
}
function recreate_nginx_container() {
  local image="${1:-}" bindings=""
  RECREATE_CALL_COUNT=$((RECREATE_CALL_COUNT + 1))
  if [ "$#" -ge 2 ]; then
    bindings="${2:-}"
  else
    bindings="${STUB_PUBLISHED_BINDINGS:-}"
  fi
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
  STUB_CONTAINER_RUNNING="${STUB_RECREATE_RUNNING_AFTER:-true}"
  STUB_PUBLISHED_BINDINGS="$bindings"
}
function remove_container_and_anonymous_volumes() {
  STUB_CONTAINER_EXISTS="false"
  STUB_CONTAINER_RUNNING="false"
  STUB_PUBLISHED_BINDINGS=""
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
      else
        printf '%s\n' "${STUB_CONTAINER_RUNNING:-false}"
      fi
      return 0
      ;;
    stop)
      STUB_CONTAINER_RUNNING="false"
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

function reset_nginx_setting_state() {
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
    "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
  : >"$TRACE_FILE"

  ENABLE_AUTO_BACKUPS="true"
  BACKUP_RETENTION="0"
  ENABLE_BACKUP_COMPRESSION="true"
  HTTP_VERSION="http1.1"
  CLIENT_IP_HEADER="X-Forwarded-For"
  PROXY_IP_HEADER="X-Real-IP"
  TLS_PROTOCOLS="TLSv1.2 TLSv1.3"
  TLS_CIPHERS="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305"
  SECURITY_RULE_STATUS="403"
  ACL_STATUS="403"
  ACL_POLICY="deny"
  TRUSTED_PROXY_RANGES=""
  REAL_IP_RECURSIVE="on"
  NGINX_IMAGE="nginx:1.28.1"
  NGINX_PULL_MODE="if-missing"
  NGINX_DOCKER_OPTS=""
  save_config
  create_nginx_config

  STUB_UPDATE_FAIL="false"
  SKIP_DOCKER_CHECKS="false"
  STUB_CONTAINER_EXISTS="true"
  STUB_CONTAINER_RUNNING="true"
  STUB_PUBLISHED_BINDINGS="80/tcp"
  STUB_RUNNING_IMAGE="$NGINX_IMAGE"
  STUB_RECREATE_FAIL_ON_CALL="0"
  STUB_RECREATE_RUNNING_AFTER="true"
  RECREATE_CALL_COUNT=0
}

function run_expect_failure() {
  local label="$1"
  shift
  local status=0
  set +e
  ("$@" >/dev/null 2>&1)
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail_test "${label} succeeded unexpectedly"
  fi
}

function run_expect_failure_same_shell() {
  local label="$1"
  shift
  local status=0
  set +e
  "$@" >/dev/null 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail_test "${label} succeeded unexpectedly"
  fi
}

# Scenario A: set_nginx_image restores saved settings when update_nginx_config fails.
reset_nginx_setting_state
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig"
STUB_UPDATE_FAIL="true"
run_expect_failure "set_nginx_image update failure" set_nginx_image nginx:mainline never
assert_same_file "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig" "set_nginx_image did not restore global_settings.csv after update failure"
assert_equals "0" "$(count_trace "recreate_nginx_container")" "set_nginx_image should not recreate nginx when update_nginx_config fails"

# Scenario B: set_nginx_image restores saved settings and runtime after recreate failure.
reset_nginx_setting_state
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig"
STUB_RECREATE_FAIL_ON_CALL="1"
run_expect_failure "set_nginx_image recreate failure" set_nginx_image nginx:mainline never
assert_same_file "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig" "set_nginx_image did not restore global_settings.csv after recreate failure"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "set_nginx_image rollback should recreate nginx a second time"
assert_trace_contains "recreate_nginx_container:2:nginx:1.28.1:80/tcp"
assert_nginx_runtime_rollback_cleared "set_nginx_image recreate failure should clear runtime rollback bookkeeping"

# Scenario C: set_nginx_docker_opts restores saved settings when update_nginx_config fails.
reset_nginx_setting_state
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig"
STUB_UPDATE_FAIL="true"
run_expect_failure "set_nginx_docker_opts update failure" set_nginx_docker_opts --cpus 1
assert_same_file "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig" "set_nginx_docker_opts did not restore global_settings.csv after update failure"
assert_equals "0" "$(count_trace "recreate_nginx_container")" "set_nginx_docker_opts should not recreate nginx when update_nginx_config fails"

# Scenario D: set_nginx_docker_opts restores saved settings and runtime after recreate failure.
reset_nginx_setting_state
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig"
STUB_RECREATE_FAIL_ON_CALL="1"
run_expect_failure "set_nginx_docker_opts recreate failure" set_nginx_docker_opts --cpus 1
assert_same_file "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig" "set_nginx_docker_opts did not restore global_settings.csv after recreate failure"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "set_nginx_docker_opts rollback should recreate nginx a second time"
assert_trace_contains "recreate_nginx_container:2:nginx:1.28.1:80/tcp"
assert_nginx_runtime_rollback_cleared "set_nginx_docker_opts recreate failure should clear runtime rollback bookkeeping"

# Scenario E: start_nginx restores saved overrides and runtime after recreate failure.
reset_nginx_setting_state
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig"
STUB_RECREATE_FAIL_ON_CALL="1"
run_expect_failure "start_nginx recreate failure" start_nginx --nginx-image nginx:mainline --docker-opts "--cpus 1"
assert_same_file "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig" "start_nginx did not restore global_settings.csv after recreate failure"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "start_nginx rollback should recreate nginx a second time"
assert_trace_contains "recreate_nginx_container:2:nginx:1.28.1:80/tcp"
assert_nginx_runtime_rollback_cleared "start_nginx recreate failure should clear runtime rollback bookkeeping"

# Scenario F: repeated same-shell failures should not leak nginx runtime rollback bookkeeping.
reset_nginx_setting_state
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig"
STUB_RECREATE_FAIL_ON_CALL="1"
run_expect_failure_same_shell "set_nginx_image same-shell recreate failure" set_nginx_image nginx:mainline never
assert_same_file "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig" "same-shell set_nginx_image failure should restore global_settings.csv"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "same-shell set_nginx_image rollback should recreate nginx a second time"
assert_nginx_runtime_rollback_cleared "same-shell set_nginx_image failure should clear runtime rollback bookkeeping"
: >"$TRACE_FILE"
RECREATE_CALL_COUNT=0
cp "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig"
STUB_RECREATE_FAIL_ON_CALL="1"
run_expect_failure_same_shell "set_nginx_docker_opts same-shell recreate failure" set_nginx_docker_opts --cpus 1
assert_same_file "$GLOBAL_SETTINGS_FILE" "$GLOBAL_SETTINGS_FILE.orig" "same-shell set_nginx_docker_opts failure should restore global_settings.csv"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "same-shell set_nginx_docker_opts rollback should still recreate nginx a second time"
assert_trace_contains "recreate_nginx_container:2:nginx:1.28.1:80/tcp"
assert_nginx_runtime_rollback_cleared "same-shell set_nginx_docker_opts failure should clear runtime rollback bookkeeping"

echo "nginx setting transaction rollback checks passed."
