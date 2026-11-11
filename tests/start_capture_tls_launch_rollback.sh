#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Exercise real TLS state and runtime-path helpers; only Docker/proxy operations
# and audit output are mocked.
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/capture.sh
source "$ROOT_DIR/lib/capture.sh"
# shellcheck source=../lib/nginx/ensure_sslkeylog_library.sh
source "$ROOT_DIR/lib/nginx/ensure_sslkeylog_library.sh"
if [ -n "${CAPTURE_START_SOURCE:-}" ]; then
  # shellcheck disable=SC1090
  source "$CAPTURE_START_SOURCE"
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_capture_launch_rollback.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
# Keep diagnostics outside command-output redirections, including failures from
# a mocked Docker operation. Failed fixtures survive the suite's state reset.
exec 9>&2
CAPTURE_TEST_COMPLETED=false
function finish_capture_fixture() {
  local status="$1"
  # Bash 3 can enter EXIT with status 0 after a nounset failure under errexit.
  if [ "$status" -eq 0 ] && [ "$CAPTURE_TEST_COMPLETED" != true ]; then status=1; fi
  if [ "$status" -eq 0 ]; then
    rm -rf "$TEST_ROOT"
  else
    {
      printf '[Diagnostics] %s: exit %s; fixture retained at %s\n' "${CASE_LABEL:-fixture setup}" "$status" "$TEST_ROOT"
      ls -ldin "$TEST_ROOT" "${STATE_DIR:-$TEST_ROOT/state}" "${EVENTS:-$TEST_ROOT/events}" "${OUTPUT:-$TEST_ROOT/output}" "${AUDIT:-$TEST_ROOT/audit}" || :
      df -Pk "$TEST_ROOT" || :
      if [ -f "${EVENTS:-}" ]; then
        printf '[Diagnostics] event bytes (hex):\n'
        od -An -tx1 -v "$EVENTS" || :
      fi
      printf '[Diagnostics] captured command output:\n'
      cat "${OUTPUT:-$TEST_ROOT/output}" || :
      printf '[Diagnostics] audit output:\n'
      cat "${AUDIT:-$TEST_ROOT/audit}" || :
    } >&9
  fi
  exit "$status"
}
trap 'finish_capture_fixture "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
BASE_DIR="$TEST_ROOT"
STATE_DIR="$TEST_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
CERTS_DIR="$STATE_DIR/certs"
TMP_DIR="$STATE_DIR/tmp"
SSLKEYLOG_LIB_SOURCE_FILE="$TEST_ROOT/sslkeylogfile.c"
printf '%s\n' 'int keylog_fixture;' >"$SSLKEYLOG_LIB_SOURCE_FILE"
EXPECTED_SOURCE_SHA256="$(_sslkeylog_source_fingerprint)"
SSLKEYLOG_LIB_BUILD_FILE="$TMP_DIR/sslkeyloglib/sslkeylogfile.so"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
BACKUP_DIR="$STATE_DIR/backups"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
ENABLE_AUTO_BACKUPS=true
ENABLE_BACKUP_COMPRESSION=true
BACKUP_RETENTION=0
CAPTURE_DIR="$STATE_DIR/pcaps"
CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
NGINX_CONTAINER_NAME="nginx-proxy"
NGINX_IMAGE="nginx:test"
CAPTURE_IMAGE="capture:test"
SKIP_DOCKER_CHECKS=false
INTERACTIVE=false
OUTPUT="$TEST_ROOT/output"
EVENTS="$TEST_ROOT/events"
AUDIT="$TEST_ROOT/audit"
RUNTIME_TLS="$TEST_ROOT/runtime-tls"
PRIOR_STATE="$TEST_ROOT/prior-state"
PRIOR_LOG="$TEST_ROOT/prior-log"
COLLISION_LOG="$CAPTURE_DIR/tls-keys/tlskeys_20261019_120000.log"
PRIOR_COLLISION_LOG="$TEST_ROOT/prior-collision-log"
ATTEMPT_STATE="$TEST_ROOT/attempt-state"
OLD_KEYLOG="$CAPTURE_DIR/tls-keys/prior-session.log"
CASE_LABEL=""
CASE_COUNT=0
CAPTURE_STATUS=42
RECREATE_CALLS=0
RECREATE_RESULTS=(0 0)
PRIOR_MODE=600
AUDIT_FAIL_ON_ENABLED=false
MOCK_PROXY_ID="prior-proxy"
MOCK_INSPECT_STATUS=0
ROLLBACK_INSPECT_FAILURE=false
WRITE_CAPTURE_CID=false
CAPTURE_ID=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
OWNED_REMOVE_STATUS=0
POST_BACKUP_FAILURE=false
MOCK_RUNNING=true
MOCK_KEYLOG_ENV=SSLKEYLOGFILE=/keys/attempt.log
MOCK_REUSE_ENV=valid
MOCK_REUSE_DIGEST=valid
MOCK_REUSE_MOUNT=valid

function fail() {
  printf '[Error] %s: %s\n' "$CASE_LABEL" "$*" >&9
  exit 1
}
function record_capture_event() {
  local status=0
  printf '%s\n' "$*" >>"$EVENTS" || status=$?
  if [ "$status" -ne 0 ]; then
    printf '[Error] %s: event write failed (exit %s): %s -> %s\n' "$CASE_LABEL" "$status" "$*" "$EVENTS" >&2
  fi
  return "$status"
}
function log_msg() { :; }
function capture_docker_logs() { :; }
function load_config() { :; }
function require_managed_nginx_container() { return 0; }
function container_running() { return 0; }
function audit_log() {
  printf '%s\n' "$*" >>"$AUDIT"
  if [ "$AUDIT_FAIL_ON_ENABLED" = true ] && [[ "$*" == *'state_change action=enabled'* ]]; then
    return 17
  fi
}
function remove_container_and_anonymous_volumes() {
  record_capture_event "remove $*" || return $?
  [ "$1" != "$CAPTURE_ID" ] || return "$OWNED_REMOVE_STATUS"
}
# Fail the real completion path after a successful capture launch. The actual
# transaction handler must restore state, invoke recovery, and remove its CID.
eval "$(declare -f backup_files_only | sed '1s/backup_files_only/_real_backup_files_only/')"
function backup_files_only() {
  if [ "$POST_BACKUP_FAILURE" = true ] && [ "$1" = post_capture_tls_launch ]; then
    return 1
  fi
  _real_backup_files_only "$@"
}
function docker() {
  case "${1:-}" in
  ps)
    # These rollback cases begin without an older capture container. Prove
    # absence using the same exact-name, full-ID query as the real lifecycle.
    [ "$*" = 'ps -a --no-trunc --filter name=^/nginx-capture$ --format {{.ID}}' ] || fail "unexpected capture listing: $*"
    return 0
    ;;
  inspect)
    [ "$MOCK_INSPECT_STATUS" -eq 0 ] || return "$MOCK_INSPECT_STATUS"
    case "${3:-}" in
    '{{.Id}}') printf '%s\n' "$MOCK_PROXY_ID" ;;
    '{{.State.Running}}') printf '%s\n' "$MOCK_RUNNING" ;;
    *LIBSSL_SSLKEYLOGFILE*)
      case "$MOCK_REUSE_ENV" in
      valid) printf 'SSLKEYLOGFILE=%s/prior-session.log\nLIBSSL_SSLKEYLOGFILE=%s/prior-session.log\nLD_PRELOAD=%s\n' "$NGINX_CAPTURE_KEYS_DIR" "$NGINX_CAPTURE_KEYS_DIR" "$NGINX_SSLKEYLOG_LIB_PATH" ;;
      empty) : ;;
      wrong-file) printf 'SSLKEYLOGFILE=%s/wrong.log\nLIBSSL_SSLKEYLOGFILE=%s/wrong.log\nLD_PRELOAD=%s\n' "$NGINX_CAPTURE_KEYS_DIR" "$NGINX_CAPTURE_KEYS_DIR" "$NGINX_SSLKEYLOG_LIB_PATH" ;;
      extra-preload) printf 'SSLKEYLOGFILE=%s/prior-session.log\nLIBSSL_SSLKEYLOGFILE=%s/prior-session.log\nLD_PRELOAD=/operator/a.so:%s /operator/b.so\n' "$NGINX_CAPTURE_KEYS_DIR" "$NGINX_CAPTURE_KEYS_DIR" "$NGINX_SSLKEYLOG_LIB_PATH" ;;
      wrong-preload) printf 'SSLKEYLOGFILE=%s/prior-session.log\nLIBSSL_SSLKEYLOGFILE=%s/prior-session.log\nLD_PRELOAD=/wrong.so\n' "$NGINX_CAPTURE_KEYS_DIR" "$NGINX_CAPTURE_KEYS_DIR" ;;
      esac
      if [ "$MOCK_REUSE_ENV" != empty ]; then
        case "$MOCK_REUSE_DIGEST" in
        valid) printf 'DOCKISTRATE_SSLKEYLOG_SOURCE_SHA256=%s\n' "$EXPECTED_SOURCE_SHA256" ;;
        stale) printf 'DOCKISTRATE_SSLKEYLOG_SOURCE_SHA256=%064d\n' 0 ;;
        missing) : ;;
        esac
      fi
      ;;
    *SSLKEYLOGFILE*) printf '%s' "$MOCK_KEYLOG_ENV" ;;
    *Mounts*)
      case "$MOCK_REUSE_MOUNT" in
      wrong-source) printf '%s\t%s\ttrue\tbind\n' "$NGINX_CAPTURE_KEYS_DIR" "$CAPTURE_DIR/other-keys" ;;
      read-only) printf '%s\t%s\tfalse\tbind\n' "$NGINX_CAPTURE_KEYS_DIR" "$CAPTURE_DIR/tls-keys" ;;
      *) printf '%s\t%s\ttrue\tbind\n' "$NGINX_CAPTURE_KEYS_DIR" "$CAPTURE_DIR/tls-keys" ;;
      esac
      case "$MOCK_REUSE_MOUNT" in
      missing-library) : ;;
      wrong-library) printf '%s\t%s\tfalse\tbind\n' "$NGINX_SSLKEYLOG_LIB_PATH" "$TMP_DIR/wrong.so" ;;
      writable-library) printf '%s\t%s\ttrue\tbind\n' "$NGINX_SSLKEYLOG_LIB_PATH" "$SSLKEYLOG_LIB_BUILD_FILE" ;;
      *) printf '%s\t%s\tfalse\tbind\n' "$NGINX_SSLKEYLOG_LIB_PATH" "$SSLKEYLOG_LIB_BUILD_FILE" ;;
      esac
      ;;
    *) fail "unexpected inspect format: ${3:-}" ;;
    esac
    return 0
    ;;
  run) ;;
  *) fail "unexpected Docker operation: $*" ;;
  esac
  local previous="" argument="" cidfile=""
  for argument in "$@"; do
    [ "$previous" != --cidfile ] || cidfile="$argument"
    previous="$argument"
  done
  if [ "$WRITE_CAPTURE_CID" = true ]; then
    [ -n "$cidfile" ] || fail 'new TLS capture did not request an ownership CID'
    printf '%s\n' "$CAPTURE_ID" >"$cidfile"
  fi
  record_capture_event capture-run || return $?
  return "$CAPTURE_STATUS"
}
function recreate_nginx_container() {
  local result="${RECREATE_RESULTS[$RECREATE_CALLS]:-0}"
  RECREATE_CALLS=$((RECREATE_CALLS + 1))
  record_capture_event "recreate $result" || return $?
  if [ "$result" -eq 0 ] || [ "$result" -eq 2 ]; then
    MOCK_PROXY_ID="recreated-proxy-$RECREATE_CALLS"
    if capture_tls_decrypt_enabled; then
      printf '%s\n' enabled >"$RUNTIME_TLS"
    else
      printf '%s\n' disabled >"$RUNTIME_TLS"
    fi
  fi
  if [ "$RECREATE_CALLS" -eq 1 ] && [ -f "$CAPTURE_TLS_STATE_FILE" ]; then
    cp "$CAPTURE_TLS_STATE_FILE" "$ATTEMPT_STATE"
  fi
  if [ "$RECREATE_CALLS" -eq 2 ] && [ "$ROLLBACK_INSPECT_FAILURE" = true ]; then
    MOCK_INSPECT_STATUS=7
  fi
  return "$result"
}
function date() {
  case "${1:-}" in
  '+%Y%m%d_%H%M%S') printf '%s\n' 20261019_120000 ;;
  '+%Y-%m-%dT%H:%M:%S%z') printf '%s\n' 2026-10-19T12:00:00+0000 ;;
  *) command date "$@" ;;
  esac
}
function file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
function reset_case() {
  CASE_LABEL="$1"
  local prior="$2"
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$CAPTURE_DIR/tls-keys" "$CERTS_DIR" "$TMP_DIR" "$ERROR_LOG_DIR" "$BACKUP_DIR" "$ACME_WEBROOT_DIR"
  printf '%s\n' 'existing session key log must survive' >"$OLD_KEYLOG"
  chmod 600 "$OLD_KEYLOG"
  cp "$OLD_KEYLOG" "$PRIOR_LOG"
  printf '%s\n' 'a same-second key log must never be overwritten' >"$COLLISION_LOG"
  chmod 600 "$COLLISION_LOG"
  cp "$COLLISION_LOG" "$PRIOR_COLLISION_LOG"
  case "$prior" in
  absent)
    rm -f "$PRIOR_STATE"
    printf '%s\n' disabled >"$RUNTIME_TLS"
    ;;
  disabled | enabled)
    local enabled=false
    [ "$prior" != enabled ] || enabled=true
    printf 'enabled=%s\nkeylog_file=%s\nstarted_at=prior-session\noperator_note=preserve bytes\n\n' "$enabled" "$OLD_KEYLOG" >"$CAPTURE_TLS_STATE_FILE"
    chmod "$PRIOR_MODE" "$CAPTURE_TLS_STATE_FILE"
    cp "$CAPTURE_TLS_STATE_FILE" "$PRIOR_STATE"
    printf '%s\n' "$prior" >"$RUNTIME_TLS"
    ;;
  *) fail 'invalid fixture state' ;;
  esac
  : >"$OUTPUT"
  : >"$EVENTS"
  : >"$AUDIT"
  CAPTURE_STATUS=42
  AUDIT_FAIL_ON_ENABLED=false
  MOCK_PROXY_ID="prior-proxy"
  MOCK_INSPECT_STATUS=0
  ROLLBACK_INSPECT_FAILURE=false
  WRITE_CAPTURE_CID=false
  OWNED_REMOVE_STATUS=0
  POST_BACKUP_FAILURE=false
  MOCK_RUNNING=true
  MOCK_KEYLOG_ENV=SSLKEYLOGFILE=/keys/attempt.log
  MOCK_REUSE_ENV=valid
  MOCK_REUSE_DIGEST=valid
  MOCK_REUSE_MOUNT=valid
  rm -f "$ATTEMPT_STATE"
  RECREATE_CALLS=0
  RECREATE_RESULTS=(0 0)
}
function assert_prior_preserved() {
  local prior="$1"
  if [ "$prior" = absent ]; then
    [ ! -e "$CAPTURE_TLS_STATE_FILE" ] || fail 'failed launch left new TLS decrypt state'
  else
    cmp -s "$PRIOR_STATE" "$CAPTURE_TLS_STATE_FILE" || fail 'failed launch changed pre-existing TLS state bytes'
    [ "$(file_mode "$CAPTURE_TLS_STATE_FILE")" = "$PRIOR_MODE" ] || fail 'failed launch changed TLS state permissions'
  fi
  cmp -s "$PRIOR_LOG" "$OLD_KEYLOG" || fail 'failed launch changed an existing session key log'
  [ "$(file_mode "$OLD_KEYLOG")" = 600 ] || fail 'failed launch changed existing key log permissions'
  cmp -s "$PRIOR_COLLISION_LOG" "$COLLISION_LOG" || fail 'same-second attempt overwrote an existing key log'
  [ "$(file_mode "$COLLISION_LOG")" = 600 ] || fail 'same-second attempt changed key log permissions'
}
function invoke_capture_failure() {
  local status=0 marker_status=0
  local prior_exit_trap="" prior_term_trap=""
  prior_exit_trap="$(trap -p EXIT)"
  prior_term_trap="$(trap -p TERM)"
  start_capture pcaps/result "$@" >"$OUTPUT" 2>&1 || status=$?
  [ "$(trap -p EXIT)" = "$prior_exit_trap" ] && [ "$(trap -p TERM)" = "$prior_term_trap" ] || fail 'failed capture did not restore caller traps'
  [ "$status" -eq "$CAPTURE_STATUS" ] || fail "capture failure exit $CAPTURE_STATUS became $status"
  grep -Fxq capture-run "$EVENTS" || marker_status=$?
  [ "$marker_status" -eq 0 ] || fail "capture launch marker check failed (grep exit $marker_status; 1=missing marker, 2=read error)"
  if grep -Fq 'Packet capture started' "$OUTPUT"; then
    fail 'failed launch reported success'
  fi
  if transaction_is_active; then
    fail 'failed capture retained an active transaction'
  fi
  [ ! -e "$(_transaction_lock_dir)" ] || fail 'failed capture retained its transaction lock'
  CASE_COUNT=$((CASE_COUNT + 1))
}

if [ "${CAPTURE_TLS_TEST_GROUP:-rollback}" = rollback ]; then
for prior in absent disabled enabled; do
  reset_case "failed TLS capture with $prior prior state" "$prior"
  invoke_capture_failure --tls-decrypt
  assert_prior_preserved "$prior"
  expected_runtime=disabled
  [ "$prior" != enabled ] || expected_runtime=enabled
  [ "$(cat "$RUNTIME_TLS")" = "$expected_runtime" ] || fail 'proxy key logging did not return to its prior mode'
  if [ "$prior" != enabled ]; then
    [ "$RECREATE_CALLS" -eq 2 ] || fail 'newly enabled key logging was not recreated back off'
  else
    [ "$RECREATE_CALLS" -eq 0 ] || fail 'existing enabled TLS session was needlessly recreated'
    if grep -Fq 'state_change action=enabled' "$AUDIT"; then
      fail 'existing enabled TLS session was rotated'
    fi
  fi
done

for prior in absent disabled; do
  reset_case "rollback recreation status 2 with $prior prior state" "$prior"
  RECREATE_RESULTS=(0 2)
  invoke_capture_failure --tls-decrypt
  assert_prior_preserved "$prior"
  [ "$(cat "$RUNTIME_TLS")" = disabled ] || fail 'status 2 did not retain restored proxy mode'
  [ "$RECREATE_CALLS" -eq 2 ] || fail 'status 2 rollback recreation was not attempted'
  grep -Ei 'incomplete|failed' "$OUTPUT" >/dev/null || fail 'partial rollback was not reported'
  if grep -Fq 'failed. Rolled back.' "$OUTPUT"; then
    fail 'incomplete runtime rollback was reported as complete'
  fi
  for visibility in known unknown; do
    reset_case "rollback recreation status 1 with $prior prior state and $visibility runtime" "$prior"
    RECREATE_RESULTS=(0 1)
    [ "$visibility" != unknown ] || ROLLBACK_INSPECT_FAILURE=true
    invoke_capture_failure --tls-decrypt
    [ "$RECREATE_CALLS" -eq 2 ] || fail 'status 1 rollback recreation was not attempted'
    cmp -s "$ATTEMPT_STATE" "$CAPTURE_TLS_STATE_FILE" || fail 'possibly active TLS state was discarded'
    [ -f "$CAPTURE_TLS_LAUNCH_WORKSPACE/candidate.state" ] || fail 'incomplete rollback discarded recovery candidate'
    if [ "$prior" = disabled ]; then
      recovery_archive="$(find "$BACKUP_DIR" -type f -name '*pre_capture_tls_launch*.tar.gz')"
      [ -n "$recovery_archive" ] || fail 'incomplete rollback discarded prior state archive'
      tar -xOzf "$recovery_archive" config/capture_tls_decrypt.state >"$TEST_ROOT/recovered-prior-state" || fail 'prior state recovery archive was not readable'
      cmp -s "$PRIOR_STATE" "$TEST_ROOT/recovered-prior-state" || fail 'recovery archive lost exact prior state bytes'
    fi
    [ "$(cat "$RUNTIME_TLS")" = enabled ] || fail 'fixture did not model active failed-attempt key logging'
    cmp -s "$PRIOR_LOG" "$OLD_KEYLOG" || fail 'rollback failure changed an existing key log'
    cmp -s "$PRIOR_COLLISION_LOG" "$COLLISION_LOG" || fail 'rollback failure changed same-second key log'
    grep -Ei 'may.*(active|enabled)|remain.*(active|enabled)' "$OUTPUT" >/dev/null || fail 'possibly active key logging warning is missing'
    if grep -Fq 'failed. Rolled back.' "$OUTPUT"; then
      fail 'failed runtime rollback was reported as complete'
    fi
  done
done

PRIOR_MODE=640
reset_case 'failed TLS capture preserves permitted prior state mode 640' disabled
invoke_capture_failure --tls-decrypt
assert_prior_preserved disabled
PRIOR_MODE=600

for prior in absent disabled; do
  reset_case "enable publication audit failure with $prior prior state" "$prior"
  AUDIT_FAIL_ON_ENABLED=true
  status=0
  start_capture pcaps/result --tls-decrypt >"$OUTPUT" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'enable audit failure was reported as success'
  if grep -Fxq capture-run "$EVENTS"; then
    fail 'capture started after TLS enablement failed'
  fi
  assert_prior_preserved "$prior"
  [ "$(cat "$RUNTIME_TLS")" = disabled ] || fail 'failed enable changed runtime key logging'
  CASE_COUNT=$((CASE_COUNT + 1))
done

for prior in absent disabled enabled; do
  reset_case "failed non-TLS capture with $prior prior state" "$prior"
  invoke_capture_failure
  assert_prior_preserved "$prior"
  [ "$RECREATE_CALLS" -eq 0 ] || fail 'capture without --tls-decrypt recreated the proxy'
done

# A failed run may already have created a container before returning its error.
for prior in absent disabled; do
  for remove_status in 0 1; do
    reset_case "capture failure after CID creation with $prior state, cleanup=$remove_status" "$prior"
    WRITE_CAPTURE_CID=true
    OWNED_REMOVE_STATUS="$remove_status"
    invoke_capture_failure --tls-decrypt
    assert_prior_preserved "$prior"
    grep -Fxq "remove $CAPTURE_ID" "$EVENTS" || fail 'owned capture was not cleaned up by immutable ID'
    [ "$(cat "$RUNTIME_TLS")" = disabled ] || fail 'capture cleanup changed prior TLS recovery'
    if [ "$remove_status" -ne 0 ]; then
      grep -Fq 'Failed to remove capture container' "$OUTPUT" || fail 'owned capture cleanup failure was hidden'
      [ -f "$CAPTURE_TLS_LAUNCH_WORKSPACE/capture.cid" ] || fail 'failed owned cleanup discarded recovery CID'
    fi
  done
  reset_case "transaction completion failure after capture launch with $prior state" "$prior"
  CAPTURE_STATUS=0
  WRITE_CAPTURE_CID=true
  POST_BACKUP_FAILURE=true
  status=0
  start_capture pcaps/result --tls-decrypt >"$OUTPUT" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'transaction completion failure reported success'
  grep -Fxq capture-run "$EVENTS" || fail 'completion failure fixture did not launch capture'
  grep -Fxq "remove $CAPTURE_ID" "$EVENTS" || fail 'completion rollback left owned capture running'
  [ "$(grep -Fxc "remove $CAPTURE_ID" "$EVENTS")" -eq 1 ] || fail 'successful owned capture cleanup was not idempotent'
  assert_prior_preserved "$prior"
  [ "$(cat "$RUNTIME_TLS")" = disabled ] || fail 'completion rollback left key logging enabled'
  [ "$RECREATE_CALLS" -eq 2 ] || fail 'completion rollback did not recreate prior proxy mode'
  if transaction_is_active || grep -Fq 'Packet capture started' "$OUTPUT"; then
    fail 'completion failure retained a transaction or reported capture success'
  fi
  CASE_COUNT=$((CASE_COUNT + 1))

  reset_case "nested parent transaction refuses TLS setup with $prior state" "$prior"
  begin_transaction_return outer_operation "$CAPTURE_TLS_STATE_FILE" >/dev/null 2>&1 || fail 'parent transaction fixture failed'
  parent_archive="$PRE_CHANGE_BACKUP"
  status=0
  _capture_tls_launch_begin command=test >"$OUTPUT" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'TLS setup joined an unrelated parent transaction'
  transaction_is_active || fail 'rejected setup ended the parent transaction'
  [ "$PRE_CHANGE_BACKUP" = "$parent_archive" ] || fail 'rejected setup replaced parent recovery snapshot'
  [ "${TRANSACTION_DEPTH:-0}" -eq 1 ] || fail 'rejected setup changed parent depth'
  [ ! -s "$EVENTS" ] && [ ! -s "$AUDIT" ] || fail 'nested TLS setup touched runtime or audit state'
  [ "$(find "$CAPTURE_DIR/tls-keys" -type f | wc -l | tr -d ' ')" -eq 2 ] || fail 'nested TLS setup created a key log'
  assert_prior_preserved "$prior"
  _rollback_handler_common >>"$OUTPUT" 2>&1 || fail 'parent fixture rollback failed'
  CASE_COUNT=$((CASE_COUNT + 1))
done

# A failed recreation can still leave a verifiably stopped or non-key-logging
# proxy. Its restored state must not be replaced with an incorrect enabled one.
for observed in stopped no-keylog; do
  reset_case "failed rollback with verifiably $observed proxy" disabled
  RECREATE_RESULTS=(0 1)
  case "$observed" in
  stopped) MOCK_RUNNING=false ;;
  no-keylog) MOCK_KEYLOG_ENV="" ;;
  esac
  invoke_capture_failure --tls-decrypt
  assert_prior_preserved disabled
  grep -Fq 'Previous TLS state restored' "$OUTPUT" || fail 'verified safe runtime recovery was not reported'
done

for stale_case in no-env wrong-file wrong-preload wrong-mount read-only-mount inspect-failure missing-keylog missing-library wrong-library writable-library stale-helper missing-helper-version; do
  reset_case "stale enabled session $stale_case rejects before TLS mutations" enabled
  case "$stale_case" in
  no-env) MOCK_REUSE_ENV=empty ;;
  wrong-file) MOCK_REUSE_ENV=wrong-file ;;
  wrong-preload) MOCK_REUSE_ENV=wrong-preload ;;
  wrong-mount) MOCK_REUSE_MOUNT=wrong-source ;;
  read-only-mount) MOCK_REUSE_MOUNT=read-only ;;
  inspect-failure) MOCK_INSPECT_STATUS=7 ;;
  missing-keylog) rm -f "$OLD_KEYLOG" ;;
  missing-library | wrong-library | writable-library) MOCK_REUSE_MOUNT="$stale_case" ;;
  stale-helper) MOCK_REUSE_DIGEST=stale ;;
  missing-helper-version) MOCK_REUSE_DIGEST=missing ;;
  esac
  status=0
  start_capture pcaps/result --tls-decrypt >"$OUTPUT" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'stale enabled TLS runtime was accepted'
  [ ! -s "$EVENTS" ] || fail 'stale session launched capture or mutated proxy'
  cmp -s "$PRIOR_STATE" "$CAPTURE_TLS_STATE_FILE" || fail 'stale-session rejection changed enabled state'
  [ "$(file_mode "$CAPTURE_TLS_STATE_FILE")" = "$PRIOR_MODE" ] || fail 'stale-session rejection changed state mode'
  if [ "$stale_case" != missing-keylog ]; then
    assert_prior_preserved enabled
  fi
  [ "$(cat "$RUNTIME_TLS")" = enabled ] || fail 'stale-session rejection changed proxy TLS mode'
  [ "$(find "$CAPTURE_DIR/tls-keys" -type f | wc -l | tr -d ' ')" -le 2 ] || fail 'stale-session rejection created a key log'
  [ "$RECREATE_CALLS" -eq 0 ] || fail 'stale enabled session was recreated'
  if transaction_is_active; then fail 'stale-session rejection left transaction'; fi
  [ ! -e "$(_transaction_lock_dir)" ] || fail 'stale-session rejection left transaction lock'
  if grep -Fq 'state_change' "$AUDIT"; then fail 'stale-session rejection wrote a TLS state change audit entry'; fi
  case "$stale_case" in
  stale-helper | missing-helper-version)
    grep -Fq 'TLS keylog helper version; stop and re-enable TLS decrypt capture before reusing this session.' "$OUTPUT" || fail 'helper version mismatch lacked capture restart guidance'
    ;;
  esac
  CASE_COUNT=$((CASE_COUNT + 1))
done

# Successful new setup commits the real transaction, while reuse preserves the
# existing session exactly, including its keylog bytes and state mode.
for prior in absent disabled enabled; do
  reset_case "successful capture with $prior prior state" "$prior"
  CAPTURE_STATUS=0
  if [ "$prior" = enabled ]; then MOCK_REUSE_ENV=extra-preload; else WRITE_CAPTURE_CID=true; fi
  start_capture pcaps/result --tls-decrypt >"$OUTPUT" 2>&1 || fail 'successful TLS capture failed'
  grep -Fq 'Packet capture started' "$OUTPUT" || fail 'successful capture lacked success message'
  capture_tls_decrypt_enabled || fail 'successful capture did not retain enabled state'
  if transaction_is_active; then fail 'successful capture retained active transaction'; fi
  [ -z "${CAPTURE_TLS_LAUNCH_WORKSPACE:-}" ] || fail 'successful capture retained temporary workspace'
  if [ "$prior" = enabled ]; then
    assert_prior_preserved enabled
    [ "$RECREATE_CALLS" -eq 0 ] || fail 'successful reused session recreated proxy'
  else
    [ "$RECREATE_CALLS" -eq 1 ] || fail 'successful new session recreated wrong number of times'
    created_log=""
    capture_tls_keylog_file created_log || fail 'successful setup lost keylog path'
    [ -f "$created_log" ] && [ ! -L "$created_log" ] || fail 'successful keylog is not a regular file'
    [ "$(file_mode "$created_log")" = 600 ] || fail 'new keylog permissions are not restricted'
    cmp -s "$PRIOR_COLLISION_LOG" "$COLLISION_LOG" || fail 'successful setup overwrote same-second keylog'
  fi
  if grep -Fxq "remove $CAPTURE_ID" "$EVENTS"; then fail 'success removed its owned capture'; fi
  CASE_COUNT=$((CASE_COUNT + 1))
done
# Exercise actual process exit and TERM cleanup with the trusted caller EXIT
# action retained once. No external processes or real Docker resources exist.
for interruption in exit term custom-term; do
  reset_case "TLS launch interrupted by $interruption" disabled
  exit_record="$TEST_ROOT/caller-exit"
  rm -f "$exit_record"
  status=0
  (
    trap 'printf "%s\n" "$?" >>"$exit_record"' EXIT
    if [ "$interruption" = custom-term ]; then trap 'exit 71' TERM; fi
    _capture_tls_launch_begin command=interruption || exit 99
    if [ "$interruption" = exit ]; then exit 37; fi
    child_pid="$(sh -c 'echo "$PPID"')"
    kill -TERM "$child_pid"
    exit 98
  ) >"$OUTPUT" 2>&1 || status=$?
  expected_status=143
  case "$interruption" in exit) expected_status=37 ;; custom-term) expected_status=71 ;; esac
  [ "$status" -eq "$expected_status" ] || fail "interruption exit $expected_status became $status"
  [ "$(cat "$exit_record")" = "$expected_status" ] || fail 'caller EXIT action/status was not preserved exactly once'
  assert_prior_preserved disabled
  [ "$(cat "$RUNTIME_TLS")" = disabled ] || fail 'interruption left proxy key logging enabled'
  [ "$(grep -c '^recreate ' "$EVENTS")" -eq 2 ] || fail 'interruption did not recreate prior proxy mode'
  [ ! -e "$(_transaction_lock_dir)" ] || fail 'interruption left transaction lock'
  CASE_COUNT=$((CASE_COUNT + 1))
done

fi

if [ "${CAPTURE_TLS_TEST_GROUP:-rollback}" = recreate ]; then
  for initial_status in 1 2; do
    for recovery_status in 0 1 2; do
      reset_case "initial recreation $initial_status with rollback $recovery_status" absent
      RECREATE_RESULTS=("$initial_status" "$recovery_status")
      status=0
      start_capture pcaps/result --tls-decrypt >"$OUTPUT" 2>&1 || status=$?
      [ "$status" -ne 0 ] || fail 'failed initial recreation reported success'
      if grep -Fxq capture-run "$EVENTS"; then fail 'capture launched after initial proxy recreation failed'; fi
      grep -Fq 'Failed to recreate Nginx with TLS decrypt key logging enabled.' "$OUTPUT" || fail 'initial recreation failure message missing'
      if [ "$initial_status" -eq 2 ] && [ "$recovery_status" -eq 1 ]; then
        cmp -s "$ATTEMPT_STATE" "$CAPTURE_TLS_STATE_FILE" || fail 'possibly active keylog state was discarded after failed recovery'
        grep -Fq 'may remain active' "$OUTPUT" || fail 'possibly active keylog warning missing'
      else
        assert_prior_preserved absent
        [ "$(cat "$RUNTIME_TLS")" = disabled ] || fail 'initial recreation recovery left key logging active'
      fi
      if transaction_is_active; then fail 'initial recreation failure retained active transaction'; fi
      CASE_COUNT=$((CASE_COUNT + 1))
    done
  done
fi
printf 'start-capture TLS launch %s: %s cases passed.\n' "${CAPTURE_TLS_TEST_GROUP:-rollback}" "$CASE_COUNT"
CAPTURE_TEST_COMPLETED=true
