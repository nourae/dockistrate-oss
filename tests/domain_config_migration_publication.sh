#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/domain_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_migration_publication.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"
CONFIG_DIR="$STATE_DIR/config"; CERTS_DIR="$STATE_DIR/certs"
BACKUP_DIR="$STATE_DIR/backups"; TMP_DIR="$STATE_DIR/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR"
MOCK_EDIT=false; MOCK_FAIL=false

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function _config_begin_runtime_prep_lock_if_needed() { printf -v "$1" '%s' false; }
function _config_end_runtime_prep_lock_if_started() { :; }
function domain_config_runtime_recover() { :; }
function _domain_config_migration_build() {
  mkdir -p "$1/candidate/example.com/config" "$1/drafts/example.com/config" "$1/source-fingerprints"
  printf 'schema_version,role,target\n5,certificate-only,\n' >"$1/candidate/example.com/config/domain.csv"
  cp "$1/candidate/example.com/config/domain.csv" "$1/drafts/example.com/config/domain.csv"
  printf 'missing\n' >"$1/source-fingerprints/example.com"
}
function begin_transaction() {
  local target=""
  [ "$DOMAIN_CONFIG_ACTIVE" = true ] || fail_test 'Migration did not enable the durable publication journal'
  shift
  for target in "$@"; do
    case "$target" in
    "$DOMAINS_DIR" | "$DOMAINS_DIR/example.com" | "$DOMAINS_DIR/example.com/config" | "$DOMAINS_DIR/example.com/config/"*)
      fail_test 'Editable migration inputs were included in archive rollback targets' ;;
    esac
  done
  DOMAIN_CONFIG_RUNTIME_JOURNAL="$TEST_WORK/journal"
  mkdir -p "$DOMAIN_CONFIG_RUNTIME_JOURNAL"
  trap 'domain_config_source_rollback' EXIT
}
function domain_config_migrate_certificates() { :; }
function _domain_config_publish_applied() {
  if [ "$MOCK_EDIT" = true ]; then
    printf 'key,value\noperator_edit,preserve\n' >"$DOMAINS_DIR/example.com/config/settings.csv"
  fi
  [ "$MOCK_FAIL" = false ]
}
function _state_schema_write_marker() { printf '%s\n' "$1" >"$CONFIG_DIR/state_schema_version"; }
function end_transaction_success() {
  _domain_config_source_verify || return 1
  printf 'committed\n' >"$TEST_WORK/committed"
  trap - EXIT
}

MOCK_FAIL=true
if _domain_config_migrate_locked "$TEST_WORK/work"; then fail_test 'Injected migration failure succeeded'; fi
[ ! -e "$DOMAINS_DIR/example.com/config" ] || fail_test 'Rollback left its own partial migration source'
[ ! -e "$CONFIG_DIR/state_schema_version" ] || fail_test 'Failed migration published the new schema'

rm -rf "$TEST_WORK/journal"
MOCK_FAIL=false; MOCK_EDIT=true
if _domain_config_migrate_locked "$TEST_WORK/work" >"$TEST_WORK/output" 2>&1; then fail_test 'Migration committed over a concurrent editor write'; fi
grep -q 'operator_edit,preserve' "$DOMAINS_DIR/example.com/config/settings.csv" || fail_test 'Rollback lost the later operator edit'
[ ! -e "$TEST_WORK/committed" ] || fail_test 'Source verification ran after commit'
[ ! -e "$CONFIG_DIR/state_schema_version" ] || fail_test 'Concurrent edit failure published the new schema'

rm -rf "$TEST_WORK/journal" "$DOMAINS_DIR/example.com/config"
MOCK_EDIT=false
_domain_config_migrate_locked "$TEST_WORK/work"
[ -f "$DOMAINS_DIR/example.com/config/domain.csv" ] || fail_test 'Successful migration did not publish source'
[ "$(cat "$CONFIG_DIR/state_schema_version")" = 5 ] || fail_test 'Successful migration omitted the schema marker'
[ -f "$TEST_WORK/committed" ] || fail_test 'Successful migration did not commit'
printf '[PASS] migration source publication preserves concurrent edits\n'
