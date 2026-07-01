#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/global_settings/common.sh
source "$ROOT_DIR/lib/global_settings/common.sh"
# shellcheck source=../lib/global_settings/set_visibility_policy.sh
source "$ROOT_DIR/lib/global_settings/set_visibility_policy.sh"
# shellcheck source=../lib/global_settings/show_visibility_policy.sh
source "$ROOT_DIR/lib/global_settings/show_visibility_policy.sh"
# shellcheck source=../lib/global_settings/show_nginx_docker_opts.sh
source "$ROOT_DIR/lib/global_settings/show_nginx_docker_opts.sh"
# shellcheck source=../lib/headers/list_headers.sh
source "$ROOT_DIR/lib/headers/list_headers.sh"
# shellcheck source=../lib/headers/list_backend_headers.sh
source "$ROOT_DIR/lib/headers/list_backend_headers.sh"
# shellcheck source=../lib/nginx/status.sh
source "$ROOT_DIR/lib/nginx/status.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_visibility_policy.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_contains() {
  local haystack="${1:-}" needle="${2:-}" context="${3:-output}"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    fail_test "${context} missing: ${needle}"$'\n'"${haystack}"
  fi
}

function assert_not_contains() {
  local haystack="${1:-}" needle="${2:-}" context="${3:-output}"
  if grep -Fq "$needle" <<<"$haystack"; then
    fail_test "${context} unexpectedly contained: ${needle}"$'\n'"${haystack}"
  fi
}

function docker() {
  case "${1:-}" in
  ps) return 0 ;;
  *) return 1 ;;
  esac
}

function capture_tls_decrypt_enabled() { return 1; }

STATE_DIR="$TMP_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
CAPTURE_DIR="$STATE_DIR/pcaps"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
FULL_BACKUP_FILE="$STATE_DIR/backups/last_full_backup.txt"
LAST_POST_BACKUP_FILE="$STATE_DIR/backups/last_post_backup.txt"
BACKUP_DIR="$STATE_DIR/backups"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$BACKUP_DIR"
config_reset_defaults
NGINX_DOCKER_OPTS="--env NGINX_TOKEN=secret"
unset VISIBILITY_POLICY
save_config || fail_test "save_config should persist default visibility policy"

[ "$(show_visibility_policy)" = "full" ] || fail_test "default visibility policy should be full"
grep -qx 'VISIBILITY_POLICY,full' "$GLOBAL_SETTINGS_FILE" || fail_test "VISIBILITY_POLICY should persist as full"

set_visibility_policy redacted >/dev/null || fail_test "set_visibility_policy redacted should succeed"
[ "$(show_visibility_policy)" = "redacted" ] || fail_test "show_visibility_policy should return redacted"
grep -qx 'VISIBILITY_POLICY,redacted' "$GLOBAL_SETTINGS_FILE" || fail_test "VISIBILITY_POLICY should persist as redacted"
grep -qx 'NGINX_DOCKER_OPTS,--env NGINX_TOKEN=secret' "$GLOBAL_SETTINGS_FILE" || fail_test "canonical docker opts should stay full in state"

if set_visibility_policy hidden >/dev/null 2>&1; then
  fail_test "set_visibility_policy should reject invalid values"
fi

{
  printf '%s\n' "$STATE_CUSTOM_HEADERS_HEADER"
  csv_join_row response X-Token "Bearer HEADER_SECRET=secret"
} >"$CUSTOM_HEADERS_FILE"
{
  printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER"
  csv_join_row example.com request X-Backend-Token "Bearer BACKEND_SECRET=secret"
} >"$BACKEND_HEADERS_FILE"
{
  printf '%s\n' "$STATE_BACKEND_DOCKER_OPTS_HEADER"
  csv_join_row backend:example.com "--env BACKEND_TOKEN=secret"
} >"$BACKEND_DOCKER_OPTS_FILE"

show_output="$(show_nginx_docker_opts)"
assert_contains "$show_output" "[REDACTED]" "show-nginx-docker-opts redacted output"
assert_not_contains "$show_output" "NGINX_TOKEN=secret" "show-nginx-docker-opts redacted output"

headers_output="$(list_headers)"
assert_contains "$headers_output" "response X-Token [REDACTED]" "list-headers redacted output"
assert_not_contains "$headers_output" "HEADER_SECRET=secret" "list-headers redacted output"

backend_headers_output="$(list_backend_headers)"
assert_contains "$backend_headers_output" "example.com request X-Backend-Token [REDACTED]" "list-backend-headers redacted output"
assert_not_contains "$backend_headers_output" "BACKEND_SECRET=secret" "list-backend-headers redacted output"

status_output="$(
  _status_print_global_settings
  _status_print_global_headers
  _status_print_backend_header_overrides
  _status_print_backend_docker_opts
)"
assert_contains "$status_output" "Nginx Docker Opts: [REDACTED]" "status redacted output"
assert_contains "$status_output" "X-Token: [REDACTED]" "status redacted output"
assert_contains "$status_output" "example.com          | request  | X-Backend-Token      | [REDACTED]" "status redacted output"
assert_contains "$status_output" "example.com                | [REDACTED]" "status redacted output"
assert_not_contains "$status_output" "NGINX_TOKEN=secret" "status redacted output"
assert_not_contains "$status_output" "HEADER_SECRET=secret" "status redacted output"
assert_not_contains "$status_output" "BACKEND_SECRET=secret" "status redacted output"

set_visibility_policy full >/dev/null || fail_test "set_visibility_policy full should succeed"
assert_contains "$(show_nginx_docker_opts)" "NGINX_TOKEN=secret" "show-nginx-docker-opts full output"
assert_contains "$(list_headers)" "HEADER_SECRET=secret" "list-headers full output"
assert_contains "$(list_backend_headers)" "BACKEND_SECRET=secret" "list-backend-headers full output"

echo "[tests] operator_visibility_policy.sh: PASS"
