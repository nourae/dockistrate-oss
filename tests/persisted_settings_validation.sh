#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/nginx.sh
source "$ROOT_DIR/lib/nginx.sh"
source "$ROOT_DIR/tests/helpers/global_csv.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_settings_validation.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
CONFIG_DIR="$TMP_ROOT/config"
mkdir -p "$CONFIG_DIR"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
TRACE="$TMP_ROOT/trace"

function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function docker() { echo docker >>"$TRACE"; return 1; }
function begin_transaction() { echo transaction >>"$TRACE"; return 1; }
function ensure_no_nginx_container_conflict() { echo conflict >>"$TRACE"; return 1; }
function _rollback_handler() { echo rollback >>"$TRACE"; return 1; }

function write_setting() {
  test_global_csv_seed "$GLOBAL_SETTINGS_FILE" "$1" "$2"
}

function expect_bad_setting() {
  local key="$1" bad="$2"
  config_reset_defaults
  HTTP_VERSION=http1.0
  ACL_POLICY=allow
  LOAD_CONFIG_SAW_NGINX_IMAGE=previous
  write_setting "$key" "$bad"
  cp "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/before"
  if load_config >"$TMP_ROOT/output" 2>&1; then
    fail_test "load_config accepted malformed $key"
  fi
  [ "$HTTP_VERSION" = http1.0 ] && [ "$ACL_POLICY" = allow ] || fail_test "Rejected load changed active values"
  [ "$LOAD_CONFIG_SAW_NGINX_IMAGE" = previous ] || fail_test "Rejected load changed metadata"
  cmp -s "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/before" || fail_test "Rejected load wrote settings"
  grep -Fq "Invalid persisted setting $key" "$TMP_ROOT/output" || fail_test "Missing key diagnostic"
  if grep -Fq -- "$bad" "$TMP_ROOT/output"; then fail_test "Diagnostic exposed invalid value"; fi

  # Exercise the direct renderer inside a conditional: errexit alone must not
  # protect the call. No transaction, Docker inspection, or rollback may begin.
  config_reset_defaults
  printf -v "$key" '%s' "$bad"
  : >"$TRACE"
  if update_nginx_config >"$TMP_ROOT/output" 2>&1; then
    fail_test "Renderer accepted malformed $key"
  fi
  [ ! -s "$TRACE" ] || fail_test "Renderer touched runtime before rejecting $key"
}

expect_bad_setting HTTP_VERSION 'http1.1;add_header X-Injected yes;#'
expect_bad_setting CLIENT_IP_HEADER 'X-Client;return 200;#'
expect_bad_setting PROXY_IP_HEADER 'X-Proxy;return 200;#'
expect_bad_setting REAL_IP_RECURSIVE 'on;return 200;#'
expect_bad_setting ACL_POLICY invalid-policy
expect_bad_setting ACL_STATUS '403;return 200;#'
expect_bad_setting SECURITY_RULE_STATUS '403;return 200;#'
expect_bad_setting ENABLE_AUTO_BACKUPS invalid-bool
expect_bad_setting ENABLE_BACKUP_COMPRESSION invalid-bool
expect_bad_setting BACKUP_RETENTION invalid-days
expect_bad_setting TLS_PROTOCOLS 'TLSv1.2;return 200;#'
expect_bad_setting TLS_CIPHERS 'HIGH;return 200;#'
expect_bad_setting TRUSTED_PROXY_RANGES '192.0.2.1;return 200;#'
expect_bad_setting NGINX_DIRECTIVE_STRICT invalid-mode
expect_bad_setting VISIBILITY_POLICY invalid-visibility
expect_bad_setting NGINX_IMAGE '--volume=/:/host:rw'
expect_bad_setting CERTBOT_IMAGE '--privileged'
expect_bad_setting NGINX_PULL_MODE invalid-pull
expect_bad_setting CERTBOT_PULL_MODE invalid-pull
expect_bad_setting NGINX_DOCKER_OPTS '--use-api-socket another-image'

# Valid first fields must not leak into the caller when a later field is invalid.
config_reset_defaults
HTTP_VERSION=http1.0
test_global_csv_seed "$GLOBAL_SETTINGS_FILE" HTTP_VERSION http1.1 ACL_POLICY invalid-policy
if load_config 2>/dev/null; then fail_test "Invalid later row accepted"; fi
[ "$HTTP_VERSION" = http1.0 ] || fail_test "Partial settings were published"
write_setting HTTP_VERSION http1.1
{ IFS= read -r header; IFS= read -r record; } <"$GLOBAL_SETTINGS_FILE"
printf '%s,http_version\n%s,http2\n' "$header" "$record" >"$GLOBAL_SETTINGS_FILE"
if load_config 2>/dev/null; then fail_test "Duplicate setting accepted"; fi
[ "$HTTP_VERSION" = http1.0 ] || fail_test "Duplicate setting changed active values"

# Preserve established formats, extension keys, and deliberate operator policy.
config_reset_defaults
test_global_csv_seed "$GLOBAL_SETTINGS_FILE" HTTP_VERSION http1.1 \
  CLIENT_IP_HEADER '' PROXY_IP_HEADER '' TLS_PROTOCOLS $' TLSv1  TLSv1.1\tTLSv1.2 ' \
  TLS_CIPHERS 'ALL:@SECLEVEL=0' ACL_POLICY allow REAL_IP_RECURSIVE off \
  NGINX_DIRECTIVE_STRICT off NGINX_IMAGE 'localhost:5000/team/proxy:custom' \
  NGINX_DOCKER_OPTS '--privileged --cpus 1 --future-mode=value' EXTENSION_SETTING opaque
load_config || fail_test "Valid operator settings rejected"
[ "$HTTP_VERSION" = http1.1 ] && [ "$ACL_POLICY" = allow ] || fail_test "Valid values not applied"
[ -z "$CLIENT_IP_HEADER" ] && [ -z "$PROXY_IP_HEADER" ] || fail_test "Disabled headers not preserved"
[ "$NGINX_IMAGE" = localhost:5000/team/proxy:custom ] || fail_test "Explicit image not preserved"

# The final directive emitters must reject unsafe direct arguments too.
config_reset_defaults
if _real_ip_directives 'X-IP;return 200;#' >"$TMP_ROOT/render" 2>/dev/null; then
  fail_test "Real-IP renderer accepted unsafe header"
fi
[ ! -s "$TMP_ROOT/render" ] || fail_test "Rejected real-IP call emitted directives"
REAL_IP_RECURSIVE='on;return 200;#'
if _real_ip_directives X-Forwarded-For >"$TMP_ROOT/render" 2>/dev/null; then
  fail_test "Real-IP renderer accepted unsafe recursion"
fi
[ ! -s "$TMP_ROOT/render" ] || fail_test "Rejected recursion emitted directives"
config_reset_defaults
printf 'original\n' >"$TMP_ROOT/location"
if _write_location_block "$TMP_ROOT/location" / 192.0.2.1:80 no example.com '' '' '' off '' '1.1;return 200;#' 2>/dev/null; then
  fail_test "Location renderer accepted unsafe HTTP version"
fi
[ "$(cat "$TMP_ROOT/location")" = original ] || fail_test "Rejected location modified output"

echo '[tests] persisted_settings_validation.sh: PASS'
