#!/usr/bin/env bash
# Globals are consumed by the production modules and activation boundary below.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-restore-globals.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/live"; TMP_DIR="$STATE_DIR/tmp"; BACKUP_DIR="$STATE_DIR/backups"; CERTS_DIR="$STATE_DIR/certs"
_domain_config_bind_config "$STATE_DIR/config"
LIVE_CONFIG_DIR="$CONFIG_DIR"
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR"
config_reset_defaults
state_csv_ensure_all_state_files
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
printf '5\n' >"$CONFIG_DIR/state_schema_version"
state_backend_ports_row_backend example.com 127.0.0.1:8080 dockistrate-net >>"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_IDENTITY_HEADER" >"$CONFIG_DIR/backend_identity.csv"
printf 'example.com,%064d,%032d\n' 11 11 >>"$CONFIG_DIR/backend_identity.csv"
cp "$CONFIG_DIR/backend_identity.csv" "$TEST_WORK/live-identity"
export SKIP_DOCKER_CHECKS=true

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function check_dependencies() { :; }
function docker() { fail_test "Restore validation must not call Docker: $*"; }
# Exercise real backup parsing, candidate validation, and current ownership
# checks. Stop at the runtime boundary to keep this regression read-only.
function _domain_restore_activate() {
  [ "$CONFIG_DIR" = "$LIVE_CONFIG_DIR" ] || fail_test 'Archived configuration binding leaked into activation'
  [ "$GLOBAL_SETTINGS_FILE" = "$LIVE_CONFIG_DIR/global_settings.csv" ] || fail_test 'Archived global-settings path leaked into activation'
  [ "$NGINX_DIRECTIVE_STRICT" = "$EXPECTED_LIVE_STRICT" ] || fail_test 'Archived values escaped validation scope'
  _backend_identity_read example.com true || return 1
  [ "$BACKEND_IDENTITY_ID" = "$(printf '%064d' 11)" ] || fail_test 'Restore used archived container ownership'
  [ "$BACKEND_IDENTITY_TOKEN" = "$(printf '%032d' 11)" ] || fail_test 'Restore used archived ownership token'
  printf 'validated\n' >>"$TEST_WORK/activation"
}

archive="$TEST_WORK/archive"
mkdir -p "$archive/config" "$archive/domains" "$archive/shared"
cp "$CONFIG_DIR/"* "$archive/config/"
printf 'format_version,state_schema_version\n5,5\n' >"$archive/backup_manifest.csv"
printf 'domain\nexample.com\n' >"$archive/config/domain_inventory.csv"
printf '%s\n' "$STATE_NGINX_DIRECTIVES_HEADER" 'global,,,,raw,server_tokens,off' >"$archive/config/nginx_directives.csv"
printf '%s\n' "$STATE_BACKEND_IDENTITY_HEADER" >"$archive/config/backend_identity.csv"
printf 'example.com,%064d,%032d\n' 22 22 >>"$archive/config/backend_identity.csv"
domain_config_write_template example.com backend "$archive/domains/example.com/config"
_domain_csv_set "$archive/domains/example.com/config/backend.csv" image nginx:alpine
_domain_csv_set "$archive/domains/example.com/config/backend.csv" state stopped
_domain_config_copy_inputs "$archive/domains/example.com/config" "$archive/domains/example.com/runtime/applied"

function write_archived_globals() (
  NGINX_DIRECTIVE_STRICT="$1"
  HTTP_VERSION=http1.0
  _save_config_write_rows >"$archive/config/global_settings.csv"
)
function restore_success() {
  cp "$GLOBAL_SETTINGS_FILE" "$TEST_WORK/live-globals"
  domain_config_restore_backup "$archive" >"$TEST_WORK/output" 2>&1 || {
    cat "$TEST_WORK/output" >&2; fail_test 'Saved strict-mode-off configuration was rejected';
  }
  cmp -s "$GLOBAL_SETTINGS_FILE" "$TEST_WORK/live-globals" || fail_test 'Validation changed live globals'
  cmp -s "$CONFIG_DIR/backend_identity.csv" "$TEST_WORK/live-identity" || fail_test 'Validation changed current ownership'
}

# A fresh process starts with strict mode on. Saved off must govern its raw
# directive even when current settings are incompatible or cannot be loaded.
EXPECTED_LIVE_STRICT=on
[ "$NGINX_DIRECTIVE_STRICT" = on ] || fail_test 'Fixture did not start with strict defaults'
write_archived_globals off
restore_success
printf 'malformed current global settings\n' >"$GLOBAL_SETTINGS_FILE"
restore_success
[ "$(wc -l <"$TEST_WORK/activation" | tr -d ' ')" = 2 ] || fail_test 'Successful validation did not reach activation'

# Conversely, permissive current settings cannot authorize a raw directive
# prohibited by the archive's own settings.
NGINX_DIRECTIVE_STRICT=off; EXPECTED_LIVE_STRICT=off
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
write_archived_globals on
if domain_config_restore_backup "$archive" >"$TEST_WORK/output" 2>&1; then
  fail_test 'Current strict-mode-off value bypassed archived strict mode'
fi
grep -q 'server_tokens' "$TEST_WORK/output" || fail_test 'Rejected archive did not identify its invalid directive'
[ "$(wc -l <"$TEST_WORK/activation" | tr -d ' ')" = 2 ] || fail_test 'Invalid archive reached activation'
cmp -s "$CONFIG_DIR/backend_identity.csv" "$TEST_WORK/live-identity" || fail_test 'Rejected validation changed current ownership'
printf '[PASS] restore validation uses archived globals without rebinding live ownership\n'
