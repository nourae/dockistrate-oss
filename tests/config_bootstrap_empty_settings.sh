#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/global_csv.sh"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/access_log.sh
source "$ROOT_DIR/lib/access_log.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_bootstrap_empty.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }

STATE_DIR="$TMP_ROOT/state"
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
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
STATE_SCHEMA_VERSION_FILE="$CONFIG_DIR/state_schema_version"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
INHERITANCE_FILE="$CONFIG_DIR/dedicated_host_inheritance.csv"

function reset_empty_settings() {
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR"
  : >"$GLOBAL_SETTINGS_FILE"
  chmod 777 "$CONFIG_DIR"
  config_reset_defaults
  HTTP_VERSION=http1.0
  LOAD_CONFIG_SAW_NGINX_IMAGE=previous
}

function directory_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

function expect_bootstrap_rejected() {
  local label="$1"
  rm -rf "$TMP_ROOT/before"
  cp -R "$CONFIG_DIR" "$TMP_ROOT/before"
  if bootstrap_config_runtime >"$TMP_ROOT/output" 2>&1; then
    fail_test "Bootstrap accepted $label"
  fi
  diff -r "$TMP_ROOT/before" "$CONFIG_DIR" >/dev/null || fail_test "Rejected $label changed config files"
  [ "$(directory_mode "$CONFIG_DIR")" = 777 ] || fail_test "Rejected $label repaired permissions"
  [ ! -e "$STATE_SCHEMA_VERSION_FILE" ] || fail_test "Rejected $label repaired schema"
  [ ! -e "$LOG_DIR" ] || fail_test "Rejected $label created runtime log paths"
  [ "$HTTP_VERSION" = http1.0 ] || fail_test "Rejected $label published defaults"
  [ "$LOAD_CONFIG_SAW_NGINX_IMAGE" = previous ] || fail_test "Rejected $label changed load metadata"
}

# Only bootstrap may initialize an empty global file. Direct loads and private
# restore preflight must still reject it without changing active configuration.
reset_empty_settings
if load_config >"$TMP_ROOT/output" 2>&1; then fail_test 'Direct load accepted empty settings'; fi
if validate_persisted_config_dir "$CONFIG_DIR" >"$TMP_ROOT/output" 2>&1; then
  fail_test 'Restore preflight accepted empty settings'
fi
[ "$HTTP_VERSION" = http1.0 ] || fail_test 'Empty-file validation changed active settings'
[ ! -s "$GLOBAL_SETTINGS_FILE" ] || fail_test 'Empty-file validation seeded settings'

# Valid saved overrides remain intact when globals need initialization. Stale
# active globals do not replace the defaults that startup is about to seed.
printf '%s\n' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 'example.com,http1.0' >"$BACKEND_HTTP_FILE"
printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" 'alias.example.com,yes,no,yes,no,yes' >"$INHERITANCE_FILE"
cp "$BACKEND_HTTP_FILE" "$TMP_ROOT/backend.before"
cp "$INHERITANCE_FILE" "$TMP_ROOT/inheritance.before"
# Legacy domain rows must be migrated explicitly, even when globals are empty.
expect_bootstrap_rejected 'legacy domain settings requiring explicit migration'
# This direct-module fixture tests initialization of current-schema caches;
# end-to-end domain tests cover rebuilding those caches from applied sources.
printf '%s\n' "$CURRENT_STATE_SCHEMA_VERSION" >"$STATE_SCHEMA_VERSION_FILE"
HTTP_VERSION='invalid stale value'
bootstrap_config_runtime || fail_test 'Bootstrap did not initialize empty regular settings'
[ "$(test_global_csv_get "$GLOBAL_SETTINGS_FILE" HTTP_VERSION)" = "${DEFAULT_HTTP_VERSION}" ] || fail_test 'Bootstrap did not seed default HTTP version'
[ "$HTTP_VERSION" = "$DEFAULT_HTTP_VERSION" ] || fail_test 'Bootstrap did not load seeded defaults'
cmp -s "$BACKEND_HTTP_FILE" "$TMP_ROOT/backend.before" || fail_test 'Bootstrap changed valid backend override'
cmp -s "$INHERITANCE_FILE" "$TMP_ROOT/inheritance.before" || fail_test 'Bootstrap changed valid inheritance'

# The empty-global exception must not bypass validation of any override family.
for invalid_case in http client_header proxy_header acl_policy acl_status security_status inheritance; do
  reset_empty_settings
  case "$invalid_case" in
  http) printf '%s\n' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 'example.com,http1.1;return 200;#' >"$BACKEND_HTTP_FILE" ;;
  client_header) printf '%s\n' "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" 'example.com,X-IP;return 200;#' >"$BACKEND_CLIENT_IP_HEADER_FILE" ;;
  proxy_header) printf '%s\n' "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" 'example.com,X-Proxy;return 200;#' >"$BACKEND_PROXY_IP_HEADER_FILE" ;;
  acl_policy) printf '%s\n' "$STATE_BACKEND_ACL_POLICIES_HEADER" 'example.com,invalid-policy' >"$BACKEND_ACL_POLICY_FILE" ;;
  acl_status) printf '%s\n' "$STATE_BACKEND_ACL_STATUSES_HEADER" 'example.com,403;return 200;#' >"$BACKEND_ACL_STATUS_FILE" ;;
  security_status) printf '%s\n' "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" 'example.com,403;return 200;#' >"$BACKEND_SECURITY_RULE_STATUS_FILE" ;;
  inheritance) printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" 'alias.example.com,yes,perhaps,yes,yes,yes' >"$INHERITANCE_FILE" ;;
  esac
  expect_bootstrap_rejected "empty global settings with malformed $invalid_case"
done

# A nonempty malformed file, empty symlink, and directory must not be treated as
# the historical empty regular initialization case.
reset_empty_settings
printf ' \n' >"$GLOBAL_SETTINGS_FILE"
expect_bootstrap_rejected 'nonempty malformed global settings'
reset_empty_settings
rm "$GLOBAL_SETTINGS_FILE"
: >"$TMP_ROOT/empty-target"
ln -s "$TMP_ROOT/empty-target" "$GLOBAL_SETTINGS_FILE"
expect_bootstrap_rejected 'empty symlink global settings'
[ -L "$GLOBAL_SETTINGS_FILE" ] && [ ! -s "$TMP_ROOT/empty-target" ] || fail_test 'Bootstrap changed symlink or target'
reset_empty_settings
rm "$GLOBAL_SETTINGS_FILE"
mkdir "$GLOBAL_SETTINGS_FILE"
expect_bootstrap_rejected 'directory global settings'

# Shared globals must reject before any derived cache is published. Per-domain
# aggregate overrides are caches, so their validation must still follow repair.
function _domain_config_refresh_cache() {
  printf '%s\n' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" >"$BACKEND_HTTP_FILE"
  : >"$CONFIG_DIR/cache-refreshed"
}
reset_empty_settings
printf '%s\n' "$CURRENT_STATE_SCHEMA_VERSION" >"$STATE_SCHEMA_VERSION_FILE"
test_global_csv_seed "$GLOBAL_SETTINGS_FILE" TRUSTED_PROXY_RANGES '10.0.0.0/8; return 200;'
cp -R "$CONFIG_DIR" "$TMP_ROOT/invalid-global-before"
if bootstrap_config_runtime >"$TMP_ROOT/output" 2>&1; then
  fail_test 'Bootstrap accepted invalid shared settings before cache refresh'
fi
diff -r "$TMP_ROOT/invalid-global-before" "$CONFIG_DIR" >/dev/null || fail_test 'Invalid globals changed config before rejection'
[ ! -e "$CONFIG_DIR/cache-refreshed" ] || fail_test 'Invalid globals triggered cache refresh'
[ "$HTTP_VERSION" = http1.0 ] || fail_test 'Shared validation published defaults'
[ "$LOAD_CONFIG_SAW_NGINX_IMAGE" = previous ] || fail_test 'Shared validation changed load metadata'

# Access-log fields are shared source, not a derived domain cache. Their
# existing diagnostics must be emitted before fingerprinting or cache writes.
for access_log_case in directory symlink_directory invalid_content blank_field; do
  reset_empty_settings
  printf '%s\n' "$CURRENT_STATE_SCHEMA_VERSION" >"$STATE_SCHEMA_VERSION_FILE"
  test_global_csv_seed "$GLOBAL_SETTINGS_FILE" HTTP_VERSION 'http1.0'
  case "$access_log_case" in
  directory) mkdir "$ACCESS_LOG_FIELDS_FILE" ;;
  symlink_directory)
    mkdir "$CONFIG_DIR/access-log-target"
    ln -s "$CONFIG_DIR/access-log-target" "$ACCESS_LOG_FIELDS_FILE"
    ;;
  invalid_content) printf '%s\n' "$STATE_ACCESS_LOG_FIELDS_HEADER" 'bad;return 200;' >"$ACCESS_LOG_FIELDS_FILE" ;;
  blank_field) printf '%s\n' "$STATE_ACCESS_LOG_FIELDS_HEADER" '' >"$ACCESS_LOG_FIELDS_FILE" ;;
  esac
  rm -rf "$TMP_ROOT/access-log-before"
  cp -R "$CONFIG_DIR" "$TMP_ROOT/access-log-before"
  if bootstrap_config_runtime >"$TMP_ROOT/output" 2>&1; then
    fail_test "Bootstrap accepted $access_log_case access-log source"
  fi
  case "$access_log_case" in
  directory | symlink_directory)
    grep -Fq "Access log fields state is not a regular file: $ACCESS_LOG_FIELDS_FILE" "$TMP_ROOT/output" || fail_test 'Nonregular access-log source lost its diagnostic'
    ;;
  *) grep -Fq 'field must be non-empty' "$TMP_ROOT/output" || fail_test 'Invalid access-log source lost its diagnostic' ;;
  esac
  diff -r "$TMP_ROOT/access-log-before" "$CONFIG_DIR" >/dev/null || fail_test 'Invalid access-log source changed configuration'
  [ ! -e "$CONFIG_DIR/cache-refreshed" ] || fail_test 'Invalid access-log source triggered cache refresh'
done

reset_empty_settings
printf '%s\n' "$CURRENT_STATE_SCHEMA_VERSION" >"$STATE_SCHEMA_VERSION_FILE"
test_global_csv_seed "$GLOBAL_SETTINGS_FILE" HTTP_VERSION 'http1.0'
printf '%s\n' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 'example.com,invalid-derived-value' >"$BACKEND_HTTP_FILE"
bootstrap_config_runtime || fail_test 'Shared prevalidation blocked repairable derived overrides'
[ -f "$CONFIG_DIR/cache-refreshed" ] || fail_test 'Valid globals did not reach cache refresh'
[ "$HTTP_VERSION" = http1.0 ] || fail_test 'Cache refresh changed valid saved globals'

for global_start in missing empty; do
  reset_empty_settings
  printf '%s\n' "$CURRENT_STATE_SCHEMA_VERSION" >"$STATE_SCHEMA_VERSION_FILE"
  if [ "$global_start" = missing ]; then rm "$GLOBAL_SETTINGS_FILE"; fi
  bootstrap_config_runtime || fail_test "Cache refresh blocked $global_start settings initialization"
  [ -f "$CONFIG_DIR/cache-refreshed" ] || fail_test "$global_start globals did not reach cache refresh"
  [ "$(test_global_csv_get "$GLOBAL_SETTINGS_FILE" HTTP_VERSION)" = "${DEFAULT_HTTP_VERSION}" ] || fail_test "Cache refresh changed $global_start global defaults"
done

reset_empty_settings
printf '%s\n' "$CURRENT_STATE_SCHEMA_VERSION" >"$STATE_SCHEMA_VERSION_FILE"
printf '%s\n' "$STATE_ACCESS_LOG_FIELDS_HEADER" >"$ACCESS_LOG_FIELDS_FILE"
bootstrap_config_runtime || fail_test 'Shared prevalidation blocked header-only access-log fields'
[ -f "$CONFIG_DIR/cache-refreshed" ] || fail_test 'Header-only access-log fields blocked cache refresh'

echo '[tests] config_bootstrap_empty_settings.sh: PASS'
