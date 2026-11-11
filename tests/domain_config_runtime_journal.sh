#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backups.sh"
source "$ROOT_DIR/lib/domain_config/runtime_records.sh"
source "$ROOT_DIR/lib/domain_config/security_migration.sh"
source "$ROOT_DIR/lib/domain_config/runtime_journal.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_runtime_journal.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
STATE_DIR="$TEST_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
TMP_DIR="$STATE_DIR/tmp"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"

function fail() { echo "[Error] $*" >&2; exit 1; }
function _backend_runtime_install_signal_traps() { :; }
function _backend_launch_cleanup() { printf 'launch:%s:%s\n' "$1" "$2" >>"$TEST_ROOT/actions"; }
function _backend_identity_inspect() {
  printf 'inspect:%s\n' "$2" >>"$TEST_ROOT/actions"
  BACKEND_CONTAINER_STATUS=exited
}
function _backend_runtime_container_is_absent() { return 1; }
function remove_container_preserving_volumes() { printf 'delete:%s\n' "$1" >>"$TEST_ROOT/actions"; }
function remove_container_and_anonymous_volumes() {
  [ "${REMOVE_FAIL:-false}" != true ] || return 1
  printf 'delete:%s\n' "$1" >>"$TEST_ROOT/actions"
}
function docker() {
  case "$1" in
  inspect) printf '/retained-old\n' ;;
  rename | start | stop) printf '%s:%s\n' "$1" "$2" >>"$TEST_ROOT/actions" ;;
  *) fail "Unexpected Docker operation $*" ;;
  esac
}
function setup_transaction() {
  TRANSACTION_DEPTH=1 TRANSACTION_OWNER_PID="$$" TRANSACTION_LOCK_HELD=true ROLLBACK_DESC=journal_test
  PRE_CHANGE_BACKUP="$STATE_DIR/backup.tar.gz"
  ROLLBACK_FILES=("$CONFIG_DIR")
  : >"$TEST_ROOT/actions"
  domain_config_runtime_prepare
}

setup_transaction
_domain_runtime_record replace a.example.com old_id first old_token token-a name backend-a.example.com new_token new-a old_state running
_domain_runtime_finish_operation
_domain_runtime_record replace b.example.com old_id second old_token token-b name backend-b.example.com new_token new-b old_state stopped
_domain_runtime_finish_operation
[ ! -s "$TEST_ROOT/actions" ] || fail 'Journal recording changed runtime before commit'
domain_config_runtime_rollback
first_restore="$(sed -n '1p' "$TEST_ROOT/actions")"
[ "$first_restore" = launch:new-b:b.example.com ] || fail 'Operations were not restored in reverse order'
grep -q '^start:first$' "$TEST_ROOT/actions" || fail 'Running backend was not restarted'
if grep -q '^start:second$' "$TEST_ROOT/actions"; then fail 'Stopped backend was incorrectly started'; fi

setup_transaction
_domain_runtime_record replace a.example.com old_id first old_token token-a name backend-a.example.com new_token new-a old_state running
_domain_runtime_finish_operation
_domain_runtime_record replace b.example.com old_id second old_token token-b name backend-b.example.com new_token new-b old_state stopped
_domain_runtime_finish_operation
domain_config_runtime_commit
[ "$(_domain_runtime_get "$DOMAIN_CONFIG_RUNTIME_JOURNAL/transaction.csv" phase)" = committed ] || fail 'Commit marker missing'
[ ! -s "$TEST_ROOT/actions" ] || fail 'Commit marker deleted containers before cleanup'
domain_config_runtime_cleanup >"$TEST_ROOT/replacement-output"
grep -q '^delete:first$' "$TEST_ROOT/actions" || fail 'First deferred replacement was lost'
grep -q '^delete:second$' "$TEST_ROOT/actions" || fail 'Second deferred replacement was lost'
[ ! -s "$TEST_ROOT/replacement-output" ] || fail 'Replacement cleanup reported explicit backend removal'

# Explicit removal reports success only after committed deletion. Uninstall
# journals may omit the name, so derive the same managed name from the domain.
setup_transaction
_domain_runtime_record remove managed.test old_id removed-id old_token managed-token
_domain_runtime_finish_operation
[ ! -s "$TEST_ROOT/actions" ] || fail 'Recording removal deleted the container'
if domain_config_runtime_cleanup >"$TEST_ROOT/removal-output" 2>&1; then fail 'Cleanup accepted an uncommitted removal'; fi
[ ! -s "$TEST_ROOT/removal-output" ] || fail 'Uncommitted removal reported success'
domain_config_runtime_commit
saved_journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL"
REMOVE_FAIL=true
if domain_config_runtime_cleanup >"$TEST_ROOT/removal-output" 2>&1; then fail 'Failed removal reported cleanup success'; fi
if grep -q 'Removed backend container' "$TEST_ROOT/removal-output"; then fail 'Failed removal printed a success message'; fi
[ -d "$saved_journal" ] || fail 'Failed removal discarded its recovery journal'
REMOVE_FAIL=false
DOMAIN_CONFIG_RUNTIME_JOURNAL="$saved_journal"
domain_config_runtime_cleanup >"$TEST_ROOT/removal-output"
grep -q '^delete:removed-id$' "$TEST_ROOT/actions" || fail 'Explicit removal did not delete the verified identity'
grep -Fxq "[Info] Removed backend container 'backend-managed.test'." "$TEST_ROOT/removal-output" || fail 'Committed removal omitted the managed name'

setup_transaction
NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED=true NGINX_RUNTIME_ROLLBACK_WAS_RUNNING=true
NGINX_RUNTIME_ROLLBACK_IMAGE=nginx:alpine NGINX_RUNTIME_ROLLBACK_BINDINGS=80/tcp
NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED=false
domain_config_runtime_capture_proxy
[ "$(_domain_runtime_get "$DOMAIN_CONFIG_RUNTIME_JOURNAL/proxy.csv" NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED)" = false ] || fail 'Untouched proxy was marked for recreation'
domain_config_runtime_mark_proxy_changed
[ "$(_domain_runtime_get "$DOMAIN_CONFIG_RUNTIME_JOURNAL/proxy.csv" NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED)" = true ] || fail 'Proxy mutation intent was not durable'
safe_rm_f "$DOMAIN_CONFIG_RUNTIME_JOURNAL/proxy.csv" "$DOMAIN_CONFIG_RUNTIME_JOURNAL"
_nginx_clear_runtime_rollback_state
domain_config_runtime_rollback

# Network deletion waits until both backend and proxy endpoints are recovered.
function _domain_runtime_remove_created_network() { printf 'network:remove\n' >>"$TEST_ROOT/actions"; }
function _domain_runtime_restore_proxy() { printf 'proxy:restore\n' >>"$TEST_ROOT/actions"; }
setup_transaction
_domain_runtime_record network_create a.example.com network new-network new_token new-network-token
_domain_runtime_finish_operation
_domain_runtime_record add a.example.com new_token new-backend
_domain_runtime_finish_operation
domain_config_runtime_rollback
[ "$(sed -n '1p' "$TEST_ROOT/actions")" = launch:new-backend:a.example.com ] || fail 'Network rollback preceded backend removal'
[ "$(sed -n '2p' "$TEST_ROOT/actions")" = proxy:restore ] || fail 'Network rollback preceded proxy recovery'
[ "$(sed -n '3p' "$TEST_ROOT/actions")" = network:remove ] || fail 'Created network was not cleaned last'

# A late signal must not restore files after the durable commit boundary.
function release_transaction_lock() { TRANSACTION_LOCK_HELD=false; }
function restore_backup_archive() { fail 'Committed transaction attempted file rollback'; }
setup_transaction
_domain_runtime_record replace a.example.com old_id first old_token token-a name backend-a.example.com new_token new-a old_state running
_domain_runtime_finish_operation
domain_config_runtime_commit
_rollback_handler_common
grep -q '^delete:first$' "$TEST_ROOT/actions" || fail 'Late commit signal did not finish deferred cleanup'

# Recovery restores knowledge of paths that were absent before the snapshot.
function restore_backup_archive() {
  [ "${ROLLBACK_NEW_FILES[0]-}" = "$STATE_DIR/domains/a.example.com/certs" ] || fail 'Crash recovery lost original missing targets'
}
function load_config() { :; }
setup_transaction
safe_rm_rf "$DOMAIN_CONFIG_RUNTIME_JOURNAL" "$(_domain_runtime_journal_root)"
unset DOMAIN_CONFIG_RUNTIME_JOURNAL
ROLLBACK_FILES=("$CONFIG_DIR" "$STATE_DIR/domains/a.example.com/certs")
ROLLBACK_NEW_FILES=("$STATE_DIR/domains/a.example.com/certs")
domain_config_runtime_prepare
_domain_runtime_put "$DOMAIN_CONFIG_RUNTIME_JOURNAL/transaction.csv" owner_pid 99999999
unset DOMAIN_CONFIG_RUNTIME_JOURNAL DOMAIN_CONFIG_RUNTIME_OPERATION
mkdir "$(_domain_runtime_journal_root)/preparing.interrupted"
domain_config_runtime_recover
[ ! -d "$(_domain_runtime_journal_root)/preparing.interrupted" ] || fail 'Recovery retained incomplete preparation'

# Interrupted first initialization has no prior settings file to load. Source
# rollback must still complete without creating settings or other state files.
source "$ROOT_DIR/lib/config/load_config.sh"
source "$ROOT_DIR/lib/domain_config/common.sh"
source "$ROOT_DIR/lib/domain_config/publication.sh"
function restore_backup_archive() {
  rm -rf "$CONFIG_DIR"
  case "$RECOVERY_SETTINGS" in
  missing) ;;
  empty) mkdir -p "$CONFIG_DIR"; : >"$GLOBAL_SETTINGS_FILE" ;;
  malformed) mkdir -p "$CONFIG_DIR"; printf 'invalid settings\n' >"$GLOBAL_SETTINGS_FILE" ;;
  esac
}
mkdir -p "$TEST_ROOT/source"
printf 'schema_version,role,target\n5,certificate-only,\n' >"$TEST_ROOT/source/domain.csv"
for RECOVERY_SETTINGS in missing empty malformed; do
  mkdir -p "$CONFIG_DIR"
  ROLLBACK_NEW_FILES=()
  [ "$RECOVERY_SETTINGS" != missing ] || ROLLBACK_NEW_FILES=("$CONFIG_DIR")
  setup_transaction
  _domain_config_source_publish init.example.com "$TEST_ROOT/source" missing
  saved_journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL"
  _domain_runtime_put "$saved_journal/transaction.csv" owner_pid 99999999
  unset DOMAIN_CONFIG_RUNTIME_JOURNAL DOMAIN_CONFIG_RUNTIME_OPERATION
  HTTP_VERSION=stale-before-recovery
  if [ "$RECOVERY_SETTINGS" = malformed ]; then
    if domain_config_runtime_recover >"$TEST_ROOT/recovery-error" 2>&1; then fail 'Recovery accepted malformed prior global settings'; fi
    [ -d "$saved_journal" ] || fail 'Failed recovery discarded its journal'
    grep -qx 'invalid settings' "$GLOBAL_SETTINGS_FILE" || fail 'Recovery rewrote malformed settings'
    safe_rm_rf "$saved_journal" "$(_domain_runtime_journal_root)"
    unset DOMAIN_CONFIG_RUNTIME_JOURNAL
  else
    domain_config_runtime_recover
    [ ! -e "$STATE_DIR/domains/init.example.com/config" ] || fail 'Initial source rollback stopped before restoring draft absence'
    [ ! -e "$saved_journal" ] || fail 'Successful initial recovery retained its journal'
    [ "$HTTP_VERSION" = "$DEFAULT_HTTP_VERSION" ] || fail 'Initial recovery did not load defaults in memory'
    if [ "$RECOVERY_SETTINGS" = missing ]; then
      [ ! -e "$CONFIG_DIR" ] || fail 'Initial recovery bootstrapped a missing config directory'
    else
      [ -f "$GLOBAL_SETTINGS_FILE" ] && [ ! -s "$GLOBAL_SETTINGS_FILE" ] || fail 'Initial recovery changed the original empty settings file'
    fi
  fi
done

# A normal first-init failure must finish the same recovery immediately, not
# leave an unusable draft until a later command discovers its journal.
rm -rf "$STATE_DIR/domains/init.example.com/config"
mkdir -p "$CONFIG_DIR"
RECOVERY_SETTINGS=missing
ROLLBACK_NEW_FILES=("$CONFIG_DIR")
setup_transaction
_domain_config_source_publish init.example.com "$TEST_ROOT/source" missing
saved_journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL"
function capture_docker_logs() { :; }
function log_msg() { :; }
_rollback_handler_common >"$TEST_ROOT/init-rollback" 2>&1 || fail 'Normal first-init rollback did not finish'
[ ! -e "$STATE_DIR/domains/init.example.com/config" ] || fail 'Normal first-init rollback retained the partial draft'
[ ! -e "$CONFIG_DIR" ] || fail 'Normal first-init rollback bootstrapped settings'
[ ! -e "$saved_journal" ] || fail 'Normal first-init rollback left a pending journal'
echo 'domain config runtime journal checks passed.'
