#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/logging.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/permissions.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_runtime_symlink_guard.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function mode_of() {
  local target="${1:-}"
  local mode=""
  if mode="$(stat -c '%a' "$target" 2>/dev/null)"; then
    printf '%s' "$mode"
    return 0
  fi
  stat -f '%Lp' "$target"
}

function assert_failed_with_guard() {
  local status="${1:-0}" output="${2:-}" label="${3:-guard}"
  [ "$status" -ne 0 ] || fail_test "${label} should fail closed"
  case "$output" in
  *"Refusing to use"*"runtime"* | *"Unable to resolve"*"runtime"*) ;;
  *) fail_test "${label} did not report a runtime path guard failure: ${output}" ;;
  esac
}

function configure_paths() {
  BASE_DIR="${1:-$TMP_ROOT/repo}"
  STATE_DIR="$BASE_DIR/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  BACKUP_DIR="$STATE_DIR/backups"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
  NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
  NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  LOG_FILE="$LOG_DIR/docker_manager.log"
  AUDIT_LOG_FILE="$LOG_DIR/audit.log"
  BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
  BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
  CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
}

function reset_runtime_tree() {
  rm -rf "$TMP_ROOT/repo" "$TMP_ROOT/outside"
  mkdir -p "$STATE_DIR" "$TMP_ROOT/outside"
  config_reset_defaults
}

function expect_external_unchanged() {
  local external_dir="${1:-}" expected_mode="${2:-}" forbidden_file="${3:-}" label="${4:-external target}"
  [ "$(mode_of "$external_dir")" = "$expected_mode" ] || fail_test "${label} mode changed"
  [ ! -e "$forbidden_file" ] || fail_test "${label} was written through a symlink"
}

configure_paths

rm -rf "$TMP_ROOT/repo" "$TMP_ROOT/outside"
mkdir -p "$BASE_DIR" "$TMP_ROOT/outside/state-root"
state_mode="$(mode_of "$TMP_ROOT/outside/state-root")"
ln -s "$TMP_ROOT/outside/state-root" "$STATE_DIR"
set +e
state_output="$(ensure_runtime_state_permissions 2>&1)"
state_status=$?
set -e
assert_failed_with_guard "$state_status" "$state_output" "permissions symlinked state"
expect_external_unchanged "$TMP_ROOT/outside/state-root" "$state_mode" "$TMP_ROOT/outside/state-root/config" "external state root"

reset_runtime_tree
external_config="$TMP_ROOT/outside/config"
mkdir -p "$external_config"
config_mode="$(mode_of "$external_config")"
ln -s "$external_config" "$CONFIG_DIR"
set +e
config_output="$(_save_config_atomic_write 2>&1)"
config_status=$?
set -e
assert_failed_with_guard "$config_status" "$config_output" "save_config symlinked config"
expect_external_unchanged "$external_config" "$config_mode" "$external_config/global_settings.csv" "external config"

reset_runtime_tree
mkdir -p "$CONFIG_DIR"
external_csv_file="$TMP_ROOT/outside/backend_http_versions.csv"
ln -s "$external_csv_file" "$BACKEND_HTTP_FILE"
set +e
csv_file_output="$(csv_require_header "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 2>&1)"
csv_file_status=$?
set -e
assert_failed_with_guard "$csv_file_status" "$csv_file_output" "csv header symlinked state file"
[ ! -e "$external_csv_file" ] || fail_test "csv header initialization wrote through a symlinked state file"

reset_runtime_tree
mkdir -p "$CONFIG_DIR"
external_existing_csv="$TMP_ROOT/outside/existing_backend_http_versions.csv"
printf '%s\n' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" >"$external_existing_csv"
existing_csv_before="$(cat "$external_existing_csv")"
ln -s "$external_existing_csv" "$BACKEND_HTTP_FILE"
set +e
csv_existing_output="$(csv_require_header "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 2>&1)"
csv_existing_status=$?
set -e
assert_failed_with_guard "$csv_existing_status" "$csv_existing_output" "csv header existing symlinked state file"
[ "$(cat "$external_existing_csv")" = "$existing_csv_before" ] || fail_test "csv header validation modified an existing outside symlink target"

reset_runtime_tree
rm -rf "$CONFIG_DIR"
printf 'not a directory\n' >"$CONFIG_DIR"
set +e
csv_mkdir_output="$(csv_require_header "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 2>&1)"
csv_mkdir_status=$?
set -e
[ "$csv_mkdir_status" -ne 0 ] || fail_test "csv header creation should fail when the CSV directory path is a file"
case "$csv_mkdir_output" in
*"Failed to create CSV directory:"*) ;;
*) fail_test "csv header directory creation failure was not explicit: ${csv_mkdir_output}" ;;
esac

reset_runtime_tree
external_csv_dir="$TMP_ROOT/outside/csv-config"
mkdir -p "$external_csv_dir"
csv_dir_mode="$(mode_of "$external_csv_dir")"
ln -s "$external_csv_dir" "$CONFIG_DIR"
set +e
csv_dir_output="$(csv_require_header "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 2>&1)"
csv_dir_status=$?
set -e
assert_failed_with_guard "$csv_dir_status" "$csv_dir_output" "csv header symlinked config directory"
expect_external_unchanged "$external_csv_dir" "$csv_dir_mode" "$external_csv_dir/backend_http_versions.csv" "external csv config"

reset_runtime_tree
external_logs="$TMP_ROOT/outside/logs"
mkdir -p "$external_logs"
logs_mode="$(mode_of "$external_logs")"
ln -s "$external_logs" "$LOG_DIR"
set +e
logs_output="$(ensure_log_writable "$LOG_FILE" 2>&1)"
logs_status=$?
set -e
assert_failed_with_guard "$logs_status" "$logs_output" "ensure_log_writable symlinked logs"
expect_external_unchanged "$external_logs" "$logs_mode" "$external_logs/docker_manager.log" "external logs"

reset_runtime_tree
external_certs="$TMP_ROOT/outside/certs"
mkdir -p "$external_certs"
certs_mode="$(mode_of "$external_certs")"
ln -s "$external_certs" "$CERTS_DIR"
set +e
certs_output="$(ensure_runtime_state_permissions 2>&1)"
certs_status=$?
set -e
assert_failed_with_guard "$certs_status" "$certs_output" "permissions symlinked certs"
expect_external_unchanged "$external_certs" "$certs_mode" "$external_certs/created-by-guard" "external certs"

reset_runtime_tree
mkdir -p "$CERTS_DIR"
external_mtls="$TMP_ROOT/outside/mtls-root"
mkdir -p "$external_mtls"
mtls_mode="$(mode_of "$external_mtls")"
ln -s "$external_mtls" "$CERTS_DIR/mtls"
set +e
mtls_output="$(ensure_runtime_state_permissions 2>&1)"
mtls_status=$?
set -e
assert_failed_with_guard "$mtls_status" "$mtls_output" "permissions symlinked mTLS root"
expect_external_unchanged "$external_mtls" "$mtls_mode" "$external_mtls/example.com/ca.key" "external mTLS root"

reset_runtime_tree
external_acme="$TMP_ROOT/outside/acme"
mkdir -p "$external_acme"
acme_mode="$(mode_of "$external_acme")"
ln -s "$external_acme" "$ACME_WEBROOT_DIR"
set +e
acme_output="$(ensure_runtime_state_permissions 2>&1)"
acme_status=$?
set -e
assert_failed_with_guard "$acme_status" "$acme_output" "permissions symlinked acme"
expect_external_unchanged "$external_acme" "$acme_mode" "$external_acme/created-by-guard" "external acme"

reset_runtime_tree
mkdir -p "$CONFIG_DIR"
external_nginx="$TMP_ROOT/outside/nginx_conf"
mkdir -p "$external_nginx"
nginx_mode="$(mode_of "$external_nginx")"
ln -s "$external_nginx" "$NGINX_CONFIG_DIR"
set +e
nginx_output="$(ensure_runtime_state_permissions 2>&1)"
nginx_status=$?
set -e
assert_failed_with_guard "$nginx_status" "$nginx_output" "permissions symlinked nginx config"
expect_external_unchanged "$external_nginx" "$nginx_mode" "$external_nginx/nginx.conf" "external nginx config"

reset_runtime_tree
LOG_FILE="$STATE_DIR/../outside/docker_manager.log"
set +e
dotdot_output="$(ensure_log_writable "$LOG_FILE" 2>&1)"
dotdot_status=$?
set -e
assert_failed_with_guard "$dotdot_status" "$dotdot_output" "declared dotdot log path"
[ ! -e "$BASE_DIR/outside/docker_manager.log" ] || fail_test "dotdot log path wrote outside STATE_DIR"
configure_paths

reset_runtime_tree
trap 'fail_test "non-declared runtime guard path triggered ERR trap"' ERR
runtime_state_path_guard_if_declared "$ROOT_DIR/state/config/not-active" "non-declared runtime path"
trap - ERR

rm -rf "$TMP_ROOT/repo" "$TMP_ROOT/outside" "$TMP_ROOT/real-prefix" "$TMP_ROOT/link-prefix"
mkdir -p "$TMP_ROOT/real-prefix/repo"
ln -s "$TMP_ROOT/real-prefix" "$TMP_ROOT/link-prefix"
configure_paths "$TMP_ROOT/link-prefix/repo"
prefix_mode="$(mode_of "$TMP_ROOT/real-prefix")"
set +e
prefix_output="$(ensure_runtime_state_permissions 2>&1)"
prefix_status=$?
set -e
assert_failed_with_guard "$prefix_status" "$prefix_output" "permissions symlinked state prefix"
expect_external_unchanged "$TMP_ROOT/real-prefix" "$prefix_mode" "$TMP_ROOT/real-prefix/repo/state/config" "external state prefix"

rm -rf "$TMP_ROOT/cache-prefix" "$TMP_ROOT/cache-outside"
mkdir -p "$TMP_ROOT/cache-prefix/repo/state" "$TMP_ROOT/cache-outside"
configure_paths "$TMP_ROOT/cache-prefix/repo"
runtime_state_path_guard "$STATE_DIR" "warm runtime state root" || fail_test "initial runtime guard warmup failed"
rm -rf "$TMP_ROOT/cache-prefix"
ln -s "$TMP_ROOT/cache-outside" "$TMP_ROOT/cache-prefix"
set +e
cache_output="$(ensure_log_writable "$LOG_FILE" 2>&1)"
cache_status=$?
set -e
assert_failed_with_guard "$cache_status" "$cache_output" "permissions symlinked state prefix after warm guard"
[ ! -e "$TMP_ROOT/cache-outside/repo/state/logs/docker_manager.log" ] || fail_test "warm guard cache allowed write through symlinked prefix"

echo "Runtime state symlink guard checks passed."
