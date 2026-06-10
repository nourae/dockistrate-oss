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
source "$ROOT_DIR/lib/access_log.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_schema.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function configure_paths() {
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
}

function reset_runtime_state() {
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
}

function write_pre_schema_settings() {
  cat >"$GLOBAL_SETTINGS_FILE" <<'EOF_CONFIG'
setting_key,setting_value
ENABLE_AUTO_BACKUPS,true
BACKUP_RETENTION,0
ENABLE_BACKUP_COMPRESSION,true
HTTP_VERSION,http2
CLIENT_IP_HEADER,X-Forwarded-For
PROXY_IP_HEADER,X-Real-IP
TLS_PROTOCOLS,TLSv1.2 TLSv1.3
TLS_CIPHERS,HIGH:!aNULL:!MD5
SECURITY_RULE_STATUS,403
ACL_STATUS,403
ACL_POLICY,deny
TRUSTED_PROXY_RANGES,
REAL_IP_RECURSIVE,on
NGINX_IMAGE,nginx
CERTBOT_IMAGE,certbot/certbot
EOF_CONFIG
}

function assert_schema_marker() {
  local expected="${1:-}" marker_file
  marker_file="$(state_schema_version_file)"
  [ -f "$marker_file" ] || fail_test "Missing state schema marker: $marker_file"
  [ "$(cat "$marker_file")" = "$expected" ] ||
    fail_test "Expected state schema marker ${expected}, got $(cat "$marker_file")"
}

function assert_bootstrap_fails_with() {
  local fixture_name="${1:-}" expected="${2:-}" status
  set +e
  bootstrap_config_runtime >"$TMP_ROOT/${fixture_name}.out" 2>"$TMP_ROOT/${fixture_name}.err"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail_test "${fixture_name} should fail bootstrap"
  grep -Fq "$expected" "$TMP_ROOT/${fixture_name}.err" ||
    fail_test "${fixture_name} failure should include: $expected"
}

function file_mtime_epoch() {
  local path="${1:-}" mtime
  if mtime="$(stat -c '%Y' "$path" 2>/dev/null)"; then
    printf '%s' "$mtime"
    return 0
  fi
  stat -f '%m' "$path"
}

configure_paths

reset_runtime_state
bootstrap_config_runtime || fail_test "fresh runtime bootstrap should write state schema marker"
assert_schema_marker "1"
bootstrap_config_runtime || fail_test "state schema bootstrap should be idempotent"
assert_schema_marker "1"

reset_runtime_state
write_pre_schema_settings
[ ! -e "$(state_schema_version_file)" ] || fail_test "pre-schema fixture should not start with marker"
bootstrap_config_runtime || fail_test "pre-schema runtime state should be treated as schema 1"
assert_schema_marker "1"
grep -qx 'TLS_CIPHERS,HIGH:!aNULL:!MD5' "$GLOBAL_SETTINGS_FILE" ||
  fail_test "pre-schema bootstrap should preserve existing settings"

reset_runtime_state
printf '%s\n' "not-a-number" >"$(state_schema_version_file)"
assert_bootstrap_fails_with "invalid" "Invalid state schema version"

reset_runtime_state
printf '%s' "1" >"$(state_schema_version_file)"
bootstrap_config_runtime || fail_test "schema marker without trailing newline should be accepted"
assert_schema_marker "1"

reset_runtime_state
marker_file="$(state_schema_version_file)"
printf '%s' "1" >"$marker_file"
touch -t 200001010000 "$marker_file" || fail_test "failed to set schema marker timestamp"
marker_checksum_before="$(cksum <"$marker_file")"
marker_mtime_before="$(file_mtime_epoch "$marker_file")"
bootstrap_config_runtime || fail_test "current schema marker should not be rewritten"
marker_checksum_after="$(cksum <"$marker_file")"
marker_mtime_after="$(file_mtime_epoch "$marker_file")"
[ "$marker_checksum_after" = "$marker_checksum_before" ] ||
  fail_test "current schema marker content changed during no-op bootstrap"
[ "$marker_mtime_after" = "$marker_mtime_before" ] ||
  fail_test "current schema marker mtime changed during no-op bootstrap"

reset_runtime_state
printf '1\n2' >"$(state_schema_version_file)"
assert_bootstrap_fails_with "extra_line_no_newline" "expected a single numeric value"

reset_runtime_state
printf '%s\n' "999999999999999999999" >"$(state_schema_version_file)"
assert_bootstrap_fails_with "overlong" "value is too large"

reset_runtime_state
printf '%s\n' "2" >"$(state_schema_version_file)"
assert_bootstrap_fails_with "newer" "Unsupported state schema version 2"

echo "state schema versioning checks passed."
