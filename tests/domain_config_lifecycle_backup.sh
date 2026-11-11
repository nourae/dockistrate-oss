#!/usr/bin/env bash
# Fixture variables are consumed by the sourced transaction/backup modules.
# shellcheck disable=SC2034
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils backends backups domain_config; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/domain-lifecycle-backup.XXXXXXXX")"
TEST_ROOT="$(cd -P "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT
BASE_DIR="$TEST_ROOT"
STATE_DIR="$TEST_ROOT/state"
DOMAINS_DIR="$STATE_DIR/domains"
CONFIG_DIR="$STATE_DIR/config"
BACKUP_DIR="$STATE_DIR/backups"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
CERTS_DIR="$STATE_DIR/certs"
FULL_BACKUP_FILE="$BACKUP_DIR/last_full_backup.txt"
FULL_BACKUP_CHECKSUM_FILE="$BACKUP_DIR/last_full_backup.sha256"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
_domain_config_bind_config "$CONFIG_DIR"
SKIP_DOCKER_CHECKS=false
INTERACTIVE=false
DOMAIN_CONFIG_ACTIVE=true
ENABLE_AUTO_BACKUPS=true
ENABLE_BACKUP_COMPRESSION=false
BACKUP_RETENTION=0
MODEL_STATE=running
TEST_ID="$(printf '%064d' 1)"
TEST_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$TMP_DIR" "$ERROR_LOG_DIR"
printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
state_csv_ensure_all_state_files
state_backend_ports_row_backend example.com 172.20.0.7:8080 dockistrate-net >>"$BACKEND_PORTS_FILE"
printf 'domain,container_id,ownership_token\nexample.com,%s,%s\n' "$TEST_ID" "$TEST_TOKEN" >"$CONFIG_DIR/backend_identity.csv"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function log_msg() { :; }
function capture_docker_logs() { :; }
function _backend_runtime_install_signal_traps() { :; }
function _backend_runtime_clear_signal_traps() { :; }
# No address changes or proxy side effects may accidentally request a backup.
function update_nginx_config() { :; }
function _domain_runtime_refresh_recovered_routes() { :; }
function _backend_container_snapshot() {
  [ "$1" = example.com ] || return 1
  BACKEND_CONTAINER_ID="$TEST_ID" BACKEND_CONTAINER_TOKEN="$TEST_TOKEN"
  BACKEND_CONTAINER_IMAGE=nginx:alpine BACKEND_CONTAINER_IMAGE_ID=sha256:saved
  BACKEND_CONTAINER_STATUS="$MODEL_STATE"
}
function _backend_identity_inspect() {
  [ "$1" = example.com ] && [ "$2" = "$TEST_ID" ] && [ "$3" = "$TEST_TOKEN" ] || return 1
  _backend_container_snapshot "$1"
}
function _backend_snapshot_network_ip() { [ "$1" = dockistrate-net ] && printf '172.20.0.7\n'; }
function docker() {
  [ "$#" = 2 ] && [ "$2" = "$TEST_ID" ] || fail_test "Unexpected Docker operation: $*"
  case "$1" in
  start | restart) MODEL_STATE=running ;;
  stop) MODEL_STATE=exited ;;
  *) fail_test "Unexpected Docker operation: $*" ;;
  esac
  printf '%s\n' "$1" >>"$TEST_ROOT/runtime-actions"
}

domain_config_write_template example.com backend "$DOMAINS_DIR/example.com/config"
_domain_csv_set "$DOMAINS_DIR/example.com/config/backend.csv" image nginx:alpine
_domain_config_copy_inputs "$DOMAINS_DIR/example.com/config" "$DOMAINS_DIR/example.com/runtime/applied"
domain_config_record_backend example.com nginx:alpine 8080 dockistrate-net running
domain_config_write_template pending.example.com certificate-only "$DOMAINS_DIR/pending.example.com/config"

# Keep real archive creation, deferred publication, source compare-and-swap,
# recovery journal and rollback; only Docker/container observations are modeled.
eval "$(declare -f domain_config_backup_write | sed '1s/domain_config_backup_write/_test_original_backup_write/')"
function domain_config_backup_write() {
  printf '%s\n' "$1" >>"$TEST_ROOT/backup-attempts"
  case "$1" in "$BACKUP_DIR"/*) [ "${FAIL_SNAPSHOT:-false}" != true ] || return 1 ;; esac
  _test_original_backup_write "$@"
}
eval "$(declare -f domain_config_runtime_commit | sed '1s/domain_config_runtime_commit/_test_original_runtime_commit/')"
function domain_config_runtime_commit() {
  if [ "${FAIL_COMMIT:-false}" = true ]; then
    FAILED_BACKUP_PATH="$(cat "$FULL_BACKUP_FILE")"
    return 1
  fi
  _test_original_runtime_commit
}
function pointer() { if [ -f "$FULL_BACKUP_FILE" ]; then cat "$FULL_BACKUP_FILE"; fi; }
function public_backups() {
  local file=""
  for file in "$BACKUP_DIR"/*/backup_manifest.csv; do [ ! -f "$file" ] || printf '%s\n' "${file%/*}"; done | LC_ALL=C sort
}
function publish_final_state() {
  local desired="$1" expected=""
  expected="$(_domain_config_input_fingerprint "$DOMAINS_DIR/example.com/config")"
  _domain_config_copy_inputs "$DOMAINS_DIR/example.com/config" "$TEST_ROOT/candidate"
  _domain_csv_set "$TEST_ROOT/candidate/backend.csv" state "$desired"
  _domain_config_copy_inputs "$TEST_ROOT/candidate" "$DOMAINS_DIR/example.com/runtime/applied"
  _domain_config_source_publish example.com "$TEST_ROOT/candidate" "$expected"
}
function assert_final_snapshot() {
  local expected="$1" snapshot="" part=""
  snapshot="$(pointer)"
  [ -f "$snapshot/backup_manifest.csv" ] || fail_test 'Lifecycle command omitted its finalized automatic backup'
  for part in config runtime/applied; do
    [ "$(domain_config_get "$snapshot/domains/example.com/$part" backend.csv state)" = "$expected" ] || fail_test "Automatic backup captured stale $part run state"
  done
  [ "$(_domain_runtime_get "$snapshot/domains/example.com/runtime/backend.csv" state)" = "$expected" ] || fail_test 'Automatic backup captured stale runtime declaration'
  [ "$(cat "$FULL_BACKUP_CHECKSUM_FILE")" = "$(cd "$snapshot" && _config_checksum .)" ] || fail_test 'Lifecycle backup checksum mismatches its payload'
  [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || fail_test 'Successful lifecycle retained a recovery journal'
}

for operation in stop start restart; do
  before_pointer="$(pointer)"
  before_declared="$(domain_config_get "$DOMAINS_DIR/example.com/config" backend.csv state)"
  desired=running; [ "$operation" != stop ] || desired=stopped
  if [ "$operation" = restart ]; then
    # Restart normally deduplicates an unchanged payload. A separately edited
    # draft ensures this test can observe its requested full backup as well.
    printf 'unfinished,"draft\n' >"$DOMAINS_DIR/pending.example.com/config/headers.csv"
  fi
  begin_transaction_return "lifecycle_$operation" "$CONFIG_DIR" "$DOMAINS_DIR/example.com/runtime"
  "${operation}_backend" example.com
  [ "$(pointer)" = "$before_pointer" ] || fail_test 'Lifecycle backed up before final source/applied publication'
  [ "$(domain_config_get "$DOMAINS_DIR/example.com/config" backend.csv state)" = "$before_declared" ] || fail_test 'Lifecycle bypassed staged source publication'
  publish_final_state "$desired"
  end_transaction_success
  [ "$(pointer)" != "$before_pointer" ] || fail_test "$operation omitted its changed automatic backup"
  assert_final_snapshot "$desired"
  grep -qx "$operation" "$TEST_ROOT/runtime-actions" || fail_test "$operation did not execute the modeled runtime action"
done
cmp -s "$DOMAINS_DIR/pending.example.com/config/headers.csv" "$(pointer)/domains/pending.example.com/config/headers.csv" || fail_test 'Restart backup lost an unrelated unfinished draft'

# Still request the ordinary deduplicating backup on a restart whose complete
# desired/applied payload is unchanged; it should not create a redundant archive.
before_pointer="$(pointer)"
before_attempts="$(wc -l <"$TEST_ROOT/backup-attempts" | tr -d '[:space:]')"
begin_transaction_return lifecycle_restart_unchanged "$CONFIG_DIR" "$DOMAINS_DIR/example.com/runtime"
restart_backend example.com
publish_final_state running
end_transaction_success
[ "$(pointer)" = "$before_pointer" ] || fail_test 'Unchanged restart created a redundant automatic backup'
[ "$(wc -l <"$TEST_ROOT/backup-attempts" | tr -d '[:space:]')" -gt "$before_attempts" ] || fail_test 'Unchanged restart skipped its automatic backup request'

for failure in snapshot commit; do
  before_pointer="$(pointer)"
  before_checksum="$(cat "$FULL_BACKUP_CHECKSUM_FILE")"
  public_backups >"$TEST_ROOT/public-before"
  before_source="$(_domain_config_input_fingerprint "$DOMAINS_DIR/example.com/config")"
  before_applied="$(_domain_config_input_fingerprint "$DOMAINS_DIR/example.com/runtime/applied")"
  begin_transaction_return "lifecycle_${failure}_failure" "$CONFIG_DIR" "$DOMAINS_DIR/example.com/runtime"
  stop_backend example.com
  publish_final_state stopped
  FAIL_SNAPSHOT=false FAIL_COMMIT=false FAILED_BACKUP_PATH=''
  if [ "$failure" = snapshot ]; then FAIL_SNAPSHOT=true; else FAIL_COMMIT=true; fi
  if end_transaction_success >"$TEST_ROOT/failure-$failure.log" 2>&1; then fail_test "$failure failure committed"; fi
  FAIL_SNAPSHOT=false FAIL_COMMIT=false
  grep -q 'Rolled back\.' "$TEST_ROOT/failure-$failure.log" || { cat "$TEST_ROOT/failure-$failure.log" >&2; fail_test "$failure failure did not roll back"; }
  [ "$MODEL_STATE" = running ] || fail_test "$failure failure left the backend stopped"
  [ "$(_domain_config_input_fingerprint "$DOMAINS_DIR/example.com/config")" = "$before_source" ] || fail_test "$failure failure left changed editable state"
  [ "$(_domain_config_input_fingerprint "$DOMAINS_DIR/example.com/runtime/applied")" = "$before_applied" ] || fail_test "$failure failure left changed applied state"
  [ "$(pointer)" = "$before_pointer" ] && [ "$(cat "$FULL_BACKUP_CHECKSUM_FILE")" = "$before_checksum" ] || fail_test "$failure failure changed public backup metadata"
  public_backups >"$TEST_ROOT/public-after"
  cmp -s "$TEST_ROOT/public-before" "$TEST_ROOT/public-after" || fail_test "$failure failure retained an uncommitted public backup"
  [ -z "$FAILED_BACKUP_PATH" ] || [ ! -e "$FAILED_BACKUP_PATH" ] || fail_test 'Late commit failure retained its completed provisional snapshot'
  [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || fail_test "$failure recovery retained a journal"
  ! transaction_is_active || fail_test "$failure recovery retained a transaction"
done

ENABLE_AUTO_BACKUPS=false
before_pointer="$(pointer)"
before_attempts="$(wc -l <"$TEST_ROOT/backup-attempts" | tr -d '[:space:]')"
begin_transaction_return lifecycle_backup_disabled "$CONFIG_DIR" "$DOMAINS_DIR/example.com/runtime"
stop_backend example.com
publish_final_state stopped
end_transaction_success
[ "$MODEL_STATE" = exited ] || fail_test 'Disabled backup policy prevented stopping the backend'
[ "$(pointer)" = "$before_pointer" ] && [ "$(wc -l <"$TEST_ROOT/backup-attempts" | tr -d '[:space:]')" = "$before_attempts" ] || fail_test 'Lifecycle ignored disabled automatic backup policy'
printf '[PASS] lifecycle commands back up final state, deduplicate unchanged restarts and retract failed snapshots\n'
