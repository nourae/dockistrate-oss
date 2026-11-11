#!/usr/bin/env bash
# Fixture globals are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
for module in backends nginx nginx_directives ports certs global_settings http_version tls mtls headers security_rules domain_config; do
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_draft_isolation.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"; CERTS_DIR="$STATE_DIR/certs"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR"
config_reset_defaults
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
state_csv_ensure_all_state_files
printf '5\n' >"$CONFIG_DIR/state_schema_version"
SKIP_DOCKER_CHECKS=true

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function docker() { fail_test 'Draft isolation attempted a Docker operation'; }
function _config_begin_runtime_prep_lock_if_needed() { printf -v "$1" '%s' false; }
function _config_end_runtime_prep_lock_if_started() { :; }
function domain_config_runtime_recover() { :; }
function begin_transaction() {
  DOMAIN_CONFIG_RUNTIME_JOURNAL="$TEST_WORK/journal-$1"
  mkdir -p "$DOMAIN_CONFIG_RUNTIME_JOURNAL"
}
function end_transaction_success() { :; }
function _domain_config_publish_generated() { :; }
function _domain_config_mark_cache() { :; }
function _run_command_impl() {
  printf '%s\n' "$*" >>"$TEST_WORK/commands"
  case "$1" in
  set-client-ip-header) printf 'global command\n' >"$TEST_WORK/global-command" ;;
  set-backend-http-version) csv_join_row "$2" "$3" >>"$BACKEND_HTTP_FILE" ;;
  *) fail_test "Unexpected command: $*" ;;
  esac
}

for domain in example.com invalid.example.com; do
  domain_config_write_template "$domain" backend "$DOMAINS_DIR/$domain/config"
  _domain_csv_set "$DOMAINS_DIR/$domain/config/backend.csv" image nginx:alpine
  _domain_config_copy_inputs "$DOMAINS_DIR/$domain/config" "$DOMAINS_DIR/$domain/runtime/applied"
  state_backend_ports_row_backend "$domain" 192.0.2.1:8080 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
done
printf 'domain\nexample.com\ninvalid.example.com\n' >"$CONFIG_DIR/domain_inventory.csv"
domain_config_write_template new.example.com backend "$DOMAINS_DIR/new.example.com/config"
mkdir "$DOMAINS_DIR/new.example.com/config/unexpected-directory"
printf 'editor data\n' >"$DOMAINS_DIR/new.example.com/config/unexpected-directory/note"
printf 'outside source\n' >"$TEST_WORK/outside"
ln -s "$TEST_WORK/outside" "$DOMAINS_DIR/invalid.example.com/config/extra.csv"
cp "$DOMAINS_DIR/invalid.example.com/config/settings.csv" "$TEST_WORK/invalid-settings-before"
cp "$DOMAINS_DIR/new.example.com/config/domain.csv" "$TEST_WORK/new-domain-before"

# Unit coverage for dispatch, guards, snapshots, adapters, and publication.
# Transaction/backup handling is substituted here: symlinks still fail the
# independent full-backup safety rules when such a backup is requested.
_domain_config_dispatch_locked "$TEST_WORK/global" set-client-ip-header X-Forwarded-For
[ -f "$TEST_WORK/global-command" ] || fail_test 'Unrelated invalid draft blocked a global command'
[ "$(cat "$TEST_WORK/global/source-fingerprints/invalid.example.com")" = unpublishable ] || fail_test 'Unsafe applied draft was not marked'
[ "$(cat "$TEST_WORK/global/source-fingerprints/new.example.com")" = unpublishable ] || fail_test 'Unsafe new draft was not marked'
_domain_config_dispatch_locked "$TEST_WORK/unrelated" set-backend-http-version example.com http2
[ "$(test_csv_field "$DOMAINS_DIR/example.com/config/settings.csv" http_version)" = http2 ] || fail_test 'Unrelated command failed to publish its source'
cmp -s "$DOMAINS_DIR/example.com/config/settings.csv" "$DOMAINS_DIR/example.com/runtime/applied/settings.csv" || fail_test 'Unrelated command failed to accept its changes'

for domain in invalid.example.com new.example.com; do
  if _domain_config_dispatch_locked "$TEST_WORK/target-$domain" set-backend-http-version "$domain" http2 >"$TEST_WORK/error" 2>&1; then
    fail_test 'A command targeting an invalid draft succeeded'
  fi
done
[ "$(wc -l <"$TEST_WORK/commands" | tr -d ' ')" = 2 ] || fail_test 'Invalid target reached the mutation'
[ -L "$DOMAINS_DIR/invalid.example.com/config/extra.csv" ] || fail_test 'Unrelated command removed the symlink'
[ "$(cat "$TEST_WORK/outside")" = 'outside source' ] || fail_test 'Unrelated command followed the symlink'
[ "$(cat "$DOMAINS_DIR/new.example.com/config/unexpected-directory/note")" = 'editor data' ] || fail_test 'Unrelated command changed invalid draft contents'
cmp -s "$TEST_WORK/invalid-settings-before" "$DOMAINS_DIR/invalid.example.com/config/settings.csv" || fail_test 'Unrelated command rewrote invalid source'
cmp -s "$TEST_WORK/new-domain-before" "$DOMAINS_DIR/new.example.com/config/domain.csv" || fail_test 'Unrelated command rewrote new draft'

# A marker is never a compare-and-swap token, even if an editor repairs the
# source before publication. A new command must take a fresh valid snapshot.
rm "$DOMAINS_DIR/invalid.example.com/config/extra.csv"
if _domain_config_source_publish invalid.example.com "$DOMAINS_DIR/example.com/config" unpublishable >"$TEST_WORK/error" 2>&1; then
  fail_test 'Publication accepted an unpublishable snapshot marker'
fi
cmp -s "$TEST_WORK/invalid-settings-before" "$DOMAINS_DIR/invalid.example.com/config/settings.csv" || fail_test 'Marker rejection modified source'

# With only an unrelated regular subdirectory remaining, exercise the real
# command, transactions, journal, and automatic full backup in private state.
(
  BASE_DIR="$TEST_WORK"
  BACKUP_DIR="$STATE_DIR/backups"; TMP_DIR="$STATE_DIR/tmp"; LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  FULL_BACKUP_FILE="$BACKUP_DIR/last_full_backup.txt"
  FULL_BACKUP_CHECKSUM_FILE="$BACKUP_DIR/last_full_backup.sha256"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  mkdir -p "$BACKUP_DIR" "$TMP_DIR" "$ERROR_LOG_DIR"
  source "$ROOT_DIR/lib/backups.sh"
  ENABLE_AUTO_BACKUPS=true ENABLE_BACKUP_COMPRESSION=false BACKUP_RETENTION=0 INTERACTIVE=false
  function log_msg() { :; }
  function capture_docker_logs() { :; }
  function update_nginx_config() { :; }
  function _run_command_impl() { shift; set_backend_http_version "$@"; }
  _domain_config_dispatch_locked "$TEST_WORK/with-backup" set-backend-http-version example.com http1.1
  [ "$(test_csv_field "$DOMAINS_DIR/example.com/config/settings.csv" http_version)" = http1.1 ] || fail_test 'Real command failed to publish beside an invalid draft'
  cmp -s "$DOMAINS_DIR/example.com/config/settings.csv" "$DOMAINS_DIR/example.com/runtime/applied/settings.csv" || fail_test 'Real command did not accept its source'
  snapshot="$(cat "$FULL_BACKUP_FILE")"
  [ -d "$snapshot" ] || fail_test 'Command did not create its automatic full backup'
  cmp -s "$DOMAINS_DIR/new.example.com/config/unexpected-directory/note" "$snapshot/domains/new.example.com/config/unexpected-directory/note" || fail_test 'Automatic backup lost the invalid draft subdirectory'
  cmp -s "$DOMAINS_DIR/example.com/config/settings.csv" "$snapshot/domains/example.com/config/settings.csv" || fail_test 'Automatic backup did not save the completed command'
  cmp -s "$TEST_WORK/new-domain-before" "$DOMAINS_DIR/new.example.com/config/domain.csv" || fail_test 'Real command changed the unrelated draft'
  [ "$(cat "$DOMAINS_DIR/new.example.com/config/unexpected-directory/note")" = 'editor data' ] || fail_test 'Real command changed the draft subdirectory'
)

printf '[PASS] Draft isolation, strict publication tokens, and automatic backup of regular draft data\n'
