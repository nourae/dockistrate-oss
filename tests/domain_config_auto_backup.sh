#!/usr/bin/env bash
# Fixture state is consumed by sourced transaction and backup functions.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils backups domain_config; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-auto-backup.XXXXXX")"
# Backup publication returns physical paths; use the same root in fault hooks.
test_root="$(cd "$test_root" && pwd -P)"
trap 'rm -rf "$test_root"' EXIT
BASE_DIR="$test_root"
STATE_DIR="$test_root/state"
DOMAINS_DIR="$STATE_DIR/domains"
CONFIG_DIR="$STATE_DIR/config"
BACKUP_DIR="$STATE_DIR/backups"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
FULL_BACKUP_FILE="$BACKUP_DIR/last_full_backup.txt"
FULL_BACKUP_CHECKSUM_FILE="$BACKUP_DIR/last_full_backup.sha256"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
_domain_config_bind_config "$CONFIG_DIR"
SKIP_DOCKER_CHECKS=true
INTERACTIVE=false
DOMAIN_CONFIG_ACTIVE=true
ENABLE_AUTO_BACKUPS=true
ENABLE_BACKUP_COMPRESSION=false
BACKUP_RETENTION=0
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$TMP_DIR" "$ERROR_LOG_DIR"
printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"

function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function log_msg() { :; }
function capture_docker_logs() { :; }
function _backend_runtime_install_signal_traps() { :; }
function _domain_runtime_restore_proxy() { MODEL_STATE="$MODEL_BEFORE"; }

# Keep real source publication, transaction archives, journal lifecycle, backup
# payload copying, and rollback. Only the external runtime is modeled.
eval "$(declare -f domain_config_backup_write | sed '1s/domain_config_backup_write/_test_backup_write/')"
function domain_config_backup_write() {
  printf '%s\n' "$1" >>"$test_root/snapshot-calls"
  case "$1" in
  "$BACKUP_DIR"/*) [ "${FAIL_SNAPSHOT:-false}" != true ] || return 1 ;;
  esac
  _test_backup_write "$@"
}
eval "$(declare -f domain_config_runtime_commit | sed '1s/domain_config_runtime_commit/_test_runtime_commit/')"
function domain_config_runtime_commit() {
  if [ "${FAIL_COMMIT:-false}" = true ]; then
    FAILED_BACKUP_PATH="$(cat "$FULL_BACKUP_FILE")"
    return 1
  fi
  _test_runtime_commit
}
function snapshot_count() {
  [ -f "$test_root/snapshot-calls" ] || { printf '0\n'; return; }
  wc -l <"$test_root/snapshot-calls" | tr -d '[:space:]'
}
function publish_candidate() {
  local expected=""
  expected="$(_domain_config_input_fingerprint "$DOMAINS_DIR/example.com/config")"
  _domain_config_copy_inputs "$test_root/candidate" "$DOMAINS_DIR/example.com/runtime/applied"
  _domain_config_source_publish example.com "$test_root/candidate" "$expected"
}

for domain in example.com pending.example.com; do
  mkdir -p "$DOMAINS_DIR/$domain/config"
  printf 'schema_version,role,target\n5,certificate-only,\n' >"$DOMAINS_DIR/$domain/config/domain.csv"
  printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.1,,,,,\n' >"$DOMAINS_DIR/$domain/config/settings.csv"
  _domain_config_copy_inputs "$DOMAINS_DIR/$domain/config" "$DOMAINS_DIR/$domain/runtime/applied"
done
printf 'unfinished,"draft\n' >"$DOMAINS_DIR/pending.example.com/config/settings.csv"
_domain_config_copy_inputs "$DOMAINS_DIR/example.com/config" "$test_root/candidate"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp2,,,,,\n' >"$test_root/candidate/settings.csv"
MODEL_STATE=before
MODEL_BEFORE=before

begin_transaction_return automatic_final_model "$CONFIG_DIR" "$DOMAINS_DIR/example.com/runtime"
printf 'domain,value\nexample.com,intermediate\n' >"$CONFIG_DIR/example_cache.csv"
MODEL_STATE=after
begin_transaction_return nested_cleanup "$CONFIG_DIR"
for request in 1 2 3 4 5 6 7 8; do
  (create_backup "" "NestedCleanup_$request")
done
[ "$(snapshot_count)" -eq 0 ] || fail_test 'Nested requests copied an intermediate model.'
[ ! -e "$FULL_BACKUP_FILE" ] && [ ! -e "$FULL_BACKUP_CHECKSUM_FILE" ] || fail_test 'Deferred request changed full-backup markers.'
end_transaction_success
[ "$(snapshot_count)" -eq 0 ] || fail_test 'Nested transaction flushed the automatic backup.'
publish_candidate
printf 'domain,value\nexample.com,final\n' >"$CONFIG_DIR/example_cache.csv"
end_transaction_success
[ "$(snapshot_count)" -eq 2 ] || fail_test 'Expected one checksum snapshot and one finalized backup.'
[ "$MODEL_STATE" = after ] || fail_test 'Successful commit restored the prior runtime.'
snapshot="$(cat "$FULL_BACKUP_FILE")"
cmp -s "$test_root/candidate/settings.csv" "$snapshot/domains/example.com/config/settings.csv" || fail_test 'Automatic backup omitted the published source.'
cmp -s "$test_root/candidate/settings.csv" "$snapshot/domains/example.com/runtime/applied/settings.csv" || fail_test 'Automatic backup captured stale applied state.'
cmp -s "$DOMAINS_DIR/pending.example.com/config/settings.csv" "$snapshot/domains/pending.example.com/config/settings.csv" || fail_test 'Automatic backup lost an unrelated pending draft.'
cmp -s "$CONFIG_DIR/example_cache.csv" "$snapshot/config/example_cache.csv" || fail_test 'Automatic backup captured intermediate aggregate state.'
[ "$(cat "$FULL_BACKUP_CHECKSUM_FILE")" = "$(cd "$snapshot" && _config_checksum .)" ] || fail_test 'Backup checksum does not describe the finalized payload.'
[ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || fail_test 'Successful commit retained a backup request.'

# A failed final snapshot must retain the previous public pointer and restore
# both applied/source files and runtime before reporting failure.
before_pointer="$(cat "$FULL_BACKUP_FILE")"
before_checksum="$(cat "$FULL_BACKUP_CHECKSUM_FILE")"
before_applied="$(cat "$DOMAINS_DIR/example.com/runtime/applied/settings.csv")"
MODEL_BEFORE="$MODEL_STATE"
begin_transaction_return automatic_snapshot_failure "$CONFIG_DIR" "$DOMAINS_DIR/example.com/runtime"
create_backup "" FailureCase
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.1,,,,,\n' >"$test_root/candidate/settings.csv"
publish_candidate
MODEL_STATE=failed_attempt
FAIL_SNAPSHOT=true
if end_transaction_success >"$test_root/failure.out" 2>&1; then fail_test 'Final snapshot failure committed.'; fi
FAIL_SNAPSHOT=false
grep -q 'Rolled back\.' "$test_root/failure.out" || { cat "$test_root/failure.out" >&2; fail_test 'Final snapshot failure did not complete rollback.'; }
[ "$MODEL_STATE" = "$MODEL_BEFORE" ] || fail_test 'Failed automatic backup left changed runtime.'
[ "$(cat "$DOMAINS_DIR/example.com/runtime/applied/settings.csv")" = "$before_applied" ] || fail_test 'Failed automatic backup left changed applied state.'
[ "$(cat "$DOMAINS_DIR/example.com/config/settings.csv")" = "$before_applied" ] || fail_test 'Failed automatic backup left its published source.'
[ "$(cat "$FULL_BACKUP_FILE")" = "$before_pointer" ] && [ "$(cat "$FULL_BACKUP_CHECKSUM_FILE")" = "$before_checksum" ] || fail_test 'Failed snapshot changed public backup markers.'
[ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || fail_test 'Rollback retained the deferred backup request.'
! transaction_is_active || fail_test 'Rollback retained the outer transaction.'

# A late durable-commit failure must also retract an already completed public
# archive and checksum, rather than advertise an uncommitted applied model.
ENABLE_BACKUP_COMPRESSION=true
BACKUP_RETENTION=1
touch -t 200001010000 "$before_pointer"
begin_transaction_return automatic_commit_failure "$CONFIG_DIR" "$DOMAINS_DIR/example.com/runtime"
create_backup "" LateFailure
publish_candidate
MODEL_STATE=failed_commit
FAIL_COMMIT=true
FAILED_BACKUP_PATH=''
if end_transaction_success >"$test_root/commit-failure.out" 2>&1; then fail_test 'Injected commit failure succeeded.'; fi
FAIL_COMMIT=false
grep -q 'Rolled back\.' "$test_root/commit-failure.out" || { cat "$test_root/commit-failure.out" >&2; fail_test 'Late backup failure did not complete rollback.'; }
case "$FAILED_BACKUP_PATH" in *.tar.gz) ;; *) fail_test 'Late-failure case did not create a compressed provisional backup.' ;; esac
[ ! -e "$FAILED_BACKUP_PATH" ] && [ ! -e "$FAILED_BACKUP_PATH.sha256" ] && [ ! -e "${FAILED_BACKUP_PATH%.tar.gz}" ] || fail_test 'Rollback retained an uncommitted public backup.'
[ "$MODEL_STATE" = "$MODEL_BEFORE" ] || fail_test 'Late backup failure left changed runtime.'
[ "$(cat "$DOMAINS_DIR/example.com/runtime/applied/settings.csv")" = "$before_applied" ] || fail_test 'Late backup failure left changed applied state.'
[ "$(cat "$FULL_BACKUP_FILE")" = "$before_pointer" ] && [ "$(cat "$FULL_BACKUP_CHECKSUM_FILE")" = "$before_checksum" ] || fail_test 'Late failure advertised an uncommitted backup.'
[ -d "$before_pointer" ] || fail_test 'Rollback deleted the preceding committed backup.'

# Manual safety snapshots remain immediate, even within an active transaction
# with automatic backups disabled.
ENABLE_AUTO_BACKUPS=false
before_count="$(snapshot_count)"
begin_transaction_return manual_snapshot "$CONFIG_DIR"
create_backup ForceManual ExplicitSafety
[ "$(snapshot_count)" -eq "$((before_count + 2))" ] || fail_test 'Manual backup was deferred or disabled.'
manual_pointer="$(cat "$FULL_BACKUP_FILE")"
case "$manual_pointer" in *_ExplicitSafety) ;; *) fail_test 'Manual backup description changed.' ;; esac
[ "$(_domain_runtime_get "$DOMAIN_CONFIG_RUNTIME_JOURNAL/transaction.csv" auto_backup_requested no)" = no ] || fail_test 'Manual backup queued an automatic snapshot.'
end_transaction_success
[ "$(snapshot_count)" -eq "$((before_count + 2))" ] || fail_test 'Manual backup caused another snapshot at commit.'

# Absence alone never authorizes skipping a queued backup. Only the explicit
# terminal uninstall flag, command, and removed-directory state may do so.
(
  ENABLE_AUTO_BACKUPS=true
  begin_transaction_return terminal_backup_guards "$CONFIG_DIR"
  create_backup "" TerminalGuard
  DOMAIN_CONFIG_TERMINAL_UNINSTALL=true DOMAIN_CONFIG_MUTATION_COMMAND=uninstall-all
  if _backup_flush_deferred_domain_backup; then fail_test 'Terminal backup skip accepted an existing config directory.'; fi
  safe_rm_rf "$CONFIG_DIR" "$STATE_DIR"
  DOMAIN_CONFIG_MUTATION_COMMAND=remove-backend
  if _backup_flush_deferred_domain_backup; then fail_test 'Another command claimed terminal backup suppression.'; fi
  DOMAIN_CONFIG_TERMINAL_UNINSTALL=false
  function create_backup() { printf 'called\n' >"$test_root/nonterminal-backup"; }
  _backup_flush_deferred_domain_backup
  [ -f "$test_root/nonterminal-backup" ] || fail_test 'Missing config alone bypassed ordinary backup handling.'
  _rollback_handler_return >/dev/null 2>&1 || true
  [ -f "$GLOBAL_SETTINGS_FILE" ] || fail_test 'Backup guard fixture did not restore its config.'
)

# Terminal config/all uninstall still completes the content transaction. A
# later commit failure restores the removed files; success leaves them absent
# without replacing the useful full-backup pointer with an empty payload.
ENABLE_AUTO_BACKUPS=true
ENABLE_BACKUP_COMPRESSION=false
BACKUP_RETENTION=0
terminal_pointer="$(cat "$FULL_BACKUP_FILE")"
terminal_checksum="$(cat "$FULL_BACKUP_CHECKSUM_FILE")"
terminal_count="$(snapshot_count)"
for domain in example.com pending.example.com; do
  _domain_config_copy_inputs "$DOMAINS_DIR/$domain/config" "$test_root/terminal-before/$domain/config"
  _domain_config_copy_inputs "$DOMAINS_DIR/$domain/runtime/applied" "$test_root/terminal-before/$domain/applied"
done
cp -R "$CONFIG_DIR" "$test_root/terminal-before/config"
MODEL_BEFORE="$MODEL_STATE"
for terminal_result in rollback success; do
  begin_transaction_return "terminal_uninstall_$terminal_result" "$CONFIG_DIR" \
    "$DOMAINS_DIR/example.com/runtime" "$DOMAINS_DIR/pending.example.com/runtime"
  create_backup "" TerminalUninstall
  DOMAIN_CONFIG_TERMINAL_UNINSTALL=true DOMAIN_CONFIG_MUTATION_COMMAND=uninstall-all
  for domain in example.com pending.example.com; do
    expected="$(_domain_config_input_fingerprint "$DOMAINS_DIR/$domain/config")"
    _domain_config_source_publish "$domain" '' "$expected"
    safe_rm_rf "$DOMAINS_DIR/$domain/runtime" "$DOMAINS_DIR/$domain"
  done
  safe_rm_rf "$CONFIG_DIR" "$STATE_DIR"
  MODEL_STATE=uninstalled
  if [ "$terminal_result" = rollback ]; then
    FAIL_COMMIT=true
    if end_transaction_success >"$test_root/terminal-failure.out" 2>&1; then fail_test 'Terminal uninstall ignored a late commit failure.'; fi
    FAIL_COMMIT=false
    grep -q 'Rolled back\.' "$test_root/terminal-failure.out" || { cat "$test_root/terminal-failure.out" >&2; fail_test 'Terminal uninstall rollback was incomplete.'; }
    diff -r "$test_root/terminal-before/config" "$CONFIG_DIR" >/dev/null || fail_test 'Terminal rollback changed the preceding config.'
    for domain in example.com pending.example.com; do
      diff -r "$test_root/terminal-before/$domain/config" "$DOMAINS_DIR/$domain/config" >/dev/null || fail_test 'Terminal rollback lost source files.'
      diff -r "$test_root/terminal-before/$domain/applied" "$DOMAINS_DIR/$domain/runtime/applied" >/dev/null || fail_test 'Terminal rollback changed applied files.'
    done
    [ "$MODEL_STATE" = "$MODEL_BEFORE" ] || fail_test 'Terminal rollback left changed runtime.'
  else
    end_transaction_success
    [ ! -e "$CONFIG_DIR" ] || fail_test 'Terminal commit recreated the removed config directory.'
    for domain in example.com pending.example.com; do
      [ ! -e "$DOMAINS_DIR/$domain/config" ] && [ ! -e "$DOMAINS_DIR/$domain/runtime" ] || fail_test 'Terminal commit recreated removed domain files.'
    done
    [ "$MODEL_STATE" = uninstalled ] || fail_test 'Terminal commit restored prior runtime.'
  fi
  [ "$(snapshot_count)" -eq "$terminal_count" ] || fail_test 'Terminal uninstall copied an unusable full backup.'
  [ "$(cat "$FULL_BACKUP_FILE")" = "$terminal_pointer" ] && [ "$(cat "$FULL_BACKUP_CHECKSUM_FILE")" = "$terminal_checksum" ] || fail_test 'Terminal uninstall replaced the useful full-backup markers.'
  [ -e "$terminal_pointer" ] || fail_test 'Terminal uninstall discarded the preceding useful backup.'
  [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || fail_test 'Terminal uninstall retained a completed journal.'
  DOMAIN_CONFIG_TERMINAL_UNINSTALL=false
done
printf '[tests] domain_config_auto_backup.sh: PASS\n'
