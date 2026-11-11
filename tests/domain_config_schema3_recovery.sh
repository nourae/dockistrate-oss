#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backups.sh"
source "$ROOT_DIR/lib/domain_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-schema3-recovery.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; TMP_DIR="$STATE_DIR/tmp"; BACKUP_DIR="$STATE_DIR/backups"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR"
TRANSACTION_LOCK_HELD=true
SKIP_DOCKER_CHECKS=true
id="$(printf '%064d' 1)"; token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TEST_CONTAINER_ID="$id"; TEST_OWNER_TOKEN="$token"
actions="$TEST_WORK/actions"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function _transaction_lock_pid_running() { return 1; }
function _backend_runtime_install_signal_traps() { :; }
function _backend_identity_inspect() {
  [ "$2" = "$TEST_CONTAINER_ID" ] && [ "$3" = "$TEST_OWNER_TOKEN" ] || return 1
  BACKEND_CONTAINER_STATUS=exited
  printf 'verified\n' >>"$actions"
}
function _backend_runtime_container_is_absent() { return 1; }
function _backend_runtime_is_full_container_id() { [ "$1" = "$TEST_CONTAINER_ID" ]; }
function _backend_identity_valid_token() { [ "$1" = "$TEST_OWNER_TOKEN" ]; }
function remove_container_preserving_volumes() { printf 'cleanup:%s\n' "$1" >>"$actions"; }
function docker() {
  [ "$1" = start ] && [ "$2" = "$TEST_CONTAINER_ID" ] || fail_test "Unexpected Docker call: $*"
  printf 'start:%s\n' "$2" >>"$actions"
}
function restore_backup_archive() {
  [ "$1" = "$TEST_WORK/old-archive.tar.gz" ] || return 1
  shift
  [ "$#" -eq 1 ] && [ "$1" = "$CONFIG_DIR" ] || return 1
  printf 'archive\n' >>"$actions"
}

printf '2\n' >"$CONFIG_DIR/state_schema_version"
printf 'setting_key,setting_value\nHTTP_VERSION,http1.0\n' >"$GLOBAL_SETTINGS_FILE"
for phase in active committed; do
  journal="$(_domain_runtime_journal_root)/apply.legacy-$phase"
  mkdir -p "$journal/operations"
  {
    printf 'key,value\nowner_pid,99999999\n'
    csv_join_row backup "$TEST_WORK/old-archive.tar.gz"
    csv_join_row target_1 "$CONFIG_DIR"
    printf 'target_1_missing,no\ntarget_count,1\nphase,%s\n' "$phase"
  } >"$journal/transaction.csv"
  mode=state; [ "$phase" != committed ] || mode=replace
  printf 'key,value\nmode,%s\ndomain,example.com\nready,yes\nold_id,%s\nold_token,%s\nold_state,running\n' \
    "$mode" "$id" "$token" >"$journal/operations/00000001.csv"
  if _domain_runtime_get "$journal/transaction.csv" phase >"$TEST_WORK/rejected" 2>&1; then
    fail_test 'Normal runtime access accepted a legacy journal'
  fi
  : >"$actions"
  domain_config_runtime_recover
  [ ! -e "$journal" ] || fail_test 'Legacy recovery retained a completed journal'
  if [ "$phase" = active ]; then
    grep -qx archive "$actions" || fail_test 'Active legacy recovery omitted archive replay'
    grep -qx "start:$id" "$actions" || fail_test 'Active legacy recovery lost running state'
    [ "$HTTP_VERSION" = http1.0 ] || fail_test 'Recovery failed to load restored legacy globals'
  else
    ! grep -qx archive "$actions" || fail_test 'Committed legacy journal rolled back'
    ! grep -q '^start:' "$actions" || fail_test 'Committed legacy journal restored prior runtime'
    grep -qx "cleanup:$id" "$actions" || fail_test 'Committed legacy journal omitted deferred cleanup'
  fi
  [ "$(cat "$CONFIG_DIR/state_schema_version")" = 2 ] || fail_test 'Legacy recovery migrated the installation implicitly'
done

# New journals use a versioned singleton and a proper target table, even when
# preparing a migration whose rollback must restore schema 2.
TRANSACTION_DEPTH=1 TRANSACTION_OWNER_PID="$$" ROLLBACK_DESC=record_test
PRE_CHANGE_BACKUP="$TEST_WORK/old-archive.tar.gz"
ROLLBACK_FILES=("$CONFIG_DIR")
ROLLBACK_NEW_FILES=()
domain_config_runtime_prepare
journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL"
[ "$(_domain_runtime_get "$journal/transaction.csv" journal_version)" = 3 ] || fail_test 'New journal is not versioned'
[ "$(_domain_runtime_get "$journal/transaction.csv" state_schema_before)" = 2 ] || fail_test 'Journal lost prior schema'
grep -qx 'position,path,originally_missing' "$journal/targets.csv" || fail_test 'New journal still uses dynamic target properties'
_domain_runtime_put "$journal/transaction.csv" owner_pid 99999999
unset DOMAIN_CONFIG_RUNTIME_JOURNAL DOMAIN_CONFIG_RUNTIME_OPERATION
: >"$actions"
domain_config_runtime_recover
grep -qx archive "$actions" || fail_test 'New journal did not decode its target records'
[ ! -e "$journal" ] || fail_test 'New-format recovery retained its completed journal'

# Changed-address healing keeps the old observation format only while replaying
# an old journal. Ordinary records after migration must use named columns.
BACKEND_CONTAINER_ID="$TEST_CONTAINER_ID" BACKEND_CONTAINER_TOKEN="$TEST_OWNER_TOKEN"
BACKEND_CONTAINER_IMAGE=nginx:alpine BACKEND_CONTAINER_IMAGE_ID=sha256:saved BACKEND_CONTAINER_STATUS=running
(
  DOMAIN_CONFIG_ACTIVE=true DOMAIN_CONFIG_RECOVERING_JOURNAL=true DOMAIN_CONFIG_LEGACY_RECOVERY=true
  domain_config_record_observed_snapshot example.com dockistrate-net 172.20.0.9
)
observation="$STATE_DIR/domains/example.com/runtime/observed.csv"
grep -qx key,value "$observation" || fail_test 'Legacy recovery changed the observation storage format'
[ "$(_domain_runtime_legacy_get "$observation" address)" = 172.20.0.9 ] || fail_test 'Legacy recovery lost the refreshed address'
printf '5\n' >"$CONFIG_DIR/state_schema_version"
DOMAIN_CONFIG_ACTIVE=true domain_config_record_observed_snapshot example.com dockistrate-net 172.20.0.10
[ "$(_domain_runtime_get "$observation" address)" = 172.20.0.10 ] || fail_test 'Current observation record lost its address'
! grep -qx key,value "$observation" || fail_test 'Current runtime wrote legacy observations'

# Schema-3 migration recovery must retain named observations, while historical
# and current state versions remain supported by the unchanged journal format.
for previous_schema in 3 4 5; do
  printf '%s\n' "$previous_schema" >"$CONFIG_DIR/state_schema_version"
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  domain_config_runtime_prepare
  journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL"
  [ "$(_domain_runtime_get "$journal/transaction.csv" state_schema_before)" = "$previous_schema" ] || fail_test 'Journal omitted prior state version'
  _domain_runtime_put "$journal/transaction.csv" owner_pid 99999999
  unset DOMAIN_CONFIG_RUNTIME_JOURNAL DOMAIN_CONFIG_RUNTIME_OPERATION
  : >"$actions"
  domain_config_runtime_recover
  grep -qx archive "$actions" || fail_test "Schema-$previous_schema recovery omitted snapshot restoration"
  (
    DOMAIN_CONFIG_ACTIVE=true DOMAIN_CONFIG_RECOVERING_JOURNAL=true DOMAIN_CONFIG_LEGACY_RECOVERY=true
    domain_config_record_observed_snapshot example.com dockistrate-net 172.20.0.11
  )
  ! grep -qx key,value "$observation" || fail_test "Schema-$previous_schema recovery regressed the observation format"
done

# Committed schema-3 certificate cleanup must use the shared issuer directory,
# even before migration starts and with the ordinary mutation model disabled.
CERTS_DIR="$STATE_DIR/certs"; DOMAINS_DIR="$STATE_DIR/domains"
for committed_schema in 3 4 5; do
  printf '%s\n' "$committed_schema" >"$CONFIG_DIR/state_schema_version"
  for issuer in "$STATE_DIR/shared/acme" "$CERTS_DIR/letsencrypt"; do
    mkdir -p "$issuer/live/example.com" "$issuer/archive/example.com" "$issuer/renewal"
    printf 'retained fixture\n' >"$issuer/live/example.com/fullchain.pem"
    printf 'retained fixture\n' >"$issuer/archive/example.com/fullchain1.pem"
    printf 'retained fixture\n' >"$issuer/renewal/example.com.conf"
  done
  domain_config_runtime_prepare
  journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL"
  _domain_runtime_record certificate_remove example.com certificate_id retained legacy_source_ref ''
  _domain_runtime_put "$journal/transaction.csv" owner_pid 99999999
  _domain_runtime_put "$journal/transaction.csv" phase committed
  # Committed migration cleanup follows marker3/4/5 rather than before3.
  _domain_runtime_put "$journal/transaction.csv" state_schema_before 3
  unset DOMAIN_CONFIG_RUNTIME_JOURNAL DOMAIN_CONFIG_RUNTIME_OPERATION DOMAIN_CONFIG_RUNTIME_CURRENT_OPERATION
  : >"$actions"
  DOMAIN_CONFIG_ACTIVE=false domain_config_runtime_recover
  [ ! -e "$STATE_DIR/shared/acme/live/example.com" ] && [ ! -e "$STATE_DIR/shared/acme/archive/example.com" ] &&
    [ ! -e "$STATE_DIR/shared/acme/renewal/example.com.conf" ] || fail_test 'Committed cleanup left shared issuer material'
  [ -f "$CERTS_DIR/letsencrypt/live/example.com/fullchain.pem" ] && [ -f "$CERTS_DIR/letsencrypt/archive/example.com/fullchain1.pem" ] &&
    [ -f "$CERTS_DIR/letsencrypt/renewal/example.com.conf" ] || fail_test 'Committed cleanup removed retained legacy issuer material'
  ! grep -qx archive "$actions" || fail_test 'Committed journal rolled back'
done

# An editor can retain an open descriptor after publication. Restore that
# original inode if it changes, and preserve both copies on a two-sided edit.
for edited in original both; do
  journal="$(_domain_runtime_journal_root)/apply.shared-$edited"
  mkdir -p "$journal"
  DOMAIN_CONFIG_RUNTIME_JOURNAL="$journal"
  printf 'original shared settings\n' >"$GLOBAL_SETTINGS_FILE"
  printf 'converted shared settings\n' >"$TEST_WORK/converted"
  before="$(_domain_config_migration_file_fingerprint "$GLOBAL_SETTINGS_FILE")"
  exec 9>>"$GLOBAL_SETTINGS_FILE"
  _domain_config_migration_file_publish global_settings.csv "$TEST_WORK/converted" "$before"
  printf 'edit through retained descriptor\n' >&9
  exec 9>&-
  if [ "$edited" = both ]; then printf 'edit to published file\n' >>"$GLOBAL_SETTINGS_FILE"; fi
  if domain_config_migration_files_verify "$journal" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Shared publication ignored an editor'; fi
  if [ "$edited" = original ]; then
    domain_config_migration_files_rollback "$journal"
    grep -qx 'original shared settings' "$GLOBAL_SETTINGS_FILE" || fail_test 'Rollback lost the original shared file'
    grep -qx 'edit through retained descriptor' "$GLOBAL_SETTINGS_FILE" || fail_test 'Rollback discarded the detached edit'
  else
    if domain_config_migration_files_rollback "$journal" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Conflicting edits reported complete recovery'; fi
    grep -qx 'edit to published file' "$GLOBAL_SETTINGS_FILE" || fail_test 'Recovery discarded the current edit'
    grep -qx 'edit through retained descriptor' "$journal/shared_sources/global_settings.csv/detached" || fail_test 'Recovery discarded the detached edit'
  fi
  unset DOMAIN_CONFIG_RUNTIME_JOURNAL
  rm -rf "$journal"
done
printf '[PASS] schema-2 journal recovery and schema-3 shared publication preserve recovery boundaries\n'
