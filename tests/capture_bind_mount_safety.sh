#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/capture.sh
source "$ROOT_DIR/lib/capture.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_capture_bind.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
BASE_DIR="$TEST_ROOT"
STATE_DIR="$TEST_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
TMP_DIR="$STATE_DIR/tmp"
CAPTURE_DIR="$STATE_DIR/pcaps"
CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
CAPTURE_IMAGE=capture:test
NGINX_CONTAINER_NAME=nginx-proxy
INTERACTIVE=false
SKIP_DOCKER_CHECKS=false
OUTSIDE="$TEST_ROOT/outside"
EVENTS="$TEST_ROOT/events"
OUTPUT="$TEST_ROOT/output"
OLD_ID="$(printf '%064d' 11)"
NEW_ID="$(printf '%064d' 12)"
CURRENT_ID="$TEST_ROOT/current-id"
CASE_COUNT=0
CASE_LABEL=setup
COMPLETED=false
HOLDER_PID=""
function finish() {
  local status="$?"
  [ "$COMPLETED" = true ] || status=1
  if [ -n "$HOLDER_PID" ]; then kill -TERM "$HOLDER_PID" 2>/dev/null || true; wait "$HOLDER_PID" 2>/dev/null || true; fi
  if [ "$status" -eq 0 ]; then rm -rf "$TEST_ROOT"; else
    printf '[Diagnostics] %s: fixture retained at %s\n' "$CASE_LABEL" "$TEST_ROOT" >&2
    cat "$OUTPUT" "$EVENTS" >&2 || true
  fi
  exit "$status"
}
trap finish EXIT
function fail() { printf '[Error] %s: %s\n' "$CASE_LABEL" "$*" >&2; exit 1; }
function record() { printf '%s\n' "$*" >>"$EVENTS"; }
function require_managed_nginx_container() { return 0; }
function container_running() { return 0; }
function capture_tls_keylog_file() { return 1; }
function capture_tls_decrypt_enabled() { [ "$TLS_ENABLED" = true ]; }
function capture_tls_decrypt_state_exists() { return 1; }
function disable_capture_tls_decrypt() { record disable; [ "$DISABLE_FAIL" = false ]; }
function recreate_nginx_container() { record recreate; [ "$RECREATE_FAIL" = false ]; }
function docker() {
  case "$1" in
  ps)
    [ "$*" = "ps -a --no-trunc --filter name=^/nginx-capture$ --format {{.ID}}" ] || fail "unexpected listing: $*"
    [ "$LIST_FAIL" = false ] || return 17
    [ ! -f "$CURRENT_ID" ] || cat "$CURRENT_ID"
    ;;
  run)
    record run
    printf '%s\0' "$@" >"$TEST_ROOT/run.argv"
    printf '%s\n' "$NEW_ID" >"$CURRENT_ID"
    ;;
  stop)
    [ "$2" = "$OLD_ID" ] || [ "$2" = "$NEW_ID" ] || fail 'stop did not use immutable ID'
    record "stop $2"
    [ "$STOP_FAIL" = false ] || return 19
    ;;
  *) fail "unexpected Docker command: $*" ;;
  esac
}
function remove_container_and_anonymous_volumes() {
  [ "$1" = "$(cat "$CURRENT_ID")" ] || fail 'removal did not use current immutable ID'
  record "remove $1"
  [ "$REMOVE_FAIL" = false ] || return 23
  if [ "$SWAP_ON_REMOVE" = true ]; then
    # Model the old writer's last rename before its successful removal. Every
    # path, including the foreign sentinel, belongs to this disposable fixture.
    mv "$CAPTURE_DIR/selected" "$CAPTURE_DIR/previous-selected"
    ln -s "$OUTSIDE" "$CAPTURE_DIR/selected"
  fi
  if [ "$REMAIN_AFTER_REMOVE" = false ]; then rm "$CURRENT_ID"; fi
}
eval "$(declare -f _capture_output_prepare | sed '1s/_capture_output_prepare/_real_capture_output_prepare/')"
function _capture_output_prepare() {
  [ ! -f "$CURRENT_ID" ] || fail 'output preparation ran while old capture existed'
  record prepare
  _real_capture_output_prepare "$@"
}
eval "$(declare -f _capture_output_verify | sed '1s/_capture_output_verify/_real_capture_output_verify/')"
function _capture_output_verify() {
  if [ "$REPLACE_BEFORE_VERIFY" = true ]; then
    mv "$CAPTURE_DIR/selected" "$CAPTURE_DIR/prepared-selected"
    mkdir "$CAPTURE_DIR/selected"
  fi
  record verify
  _real_capture_output_verify "$@"
}
function reset_case() {
  CASE_LABEL="$1"
  rm -rf "$STATE_DIR" "$OUTSIDE"
  mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$OUTSIDE"
  chmod 755 "$OUTSIDE"
  printf '%s\n' 'foreign sentinel bytes' >"$OUTSIDE/sentinel"
  printf '%s\n' "$OLD_ID" >"$CURRENT_ID"
  : >"$EVENTS"
  : >"$OUTPUT"
  rm -f "$TEST_ROOT/run.argv"
  LIST_FAIL=false REMOVE_FAIL=false STOP_FAIL=false REMAIN_AFTER_REMOVE=false
  SWAP_ON_REMOVE=false REPLACE_BEFORE_VERIFY=false
  TLS_ENABLED=false DISABLE_FAIL=false RECREATE_FAIL=false
}
function assert_foreign_unchanged() {
  [ "$(cat "$OUTSIDE/sentinel")" = 'foreign sentinel bytes' ] || fail 'foreign bytes changed'
  local mode=""
  mode="$(stat -c '%a' "$OUTSIDE" 2>/dev/null || stat -f '%Lp' "$OUTSIDE")"
  [ "$mode" = 755 ] || fail 'foreign directory permissions changed'
  [ "$(find "$OUTSIDE" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] || fail 'foreign directory gained artifacts'
}
function assert_rejected() {
  local status=0
  "$@" >"$OUTPUT" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'unsafe capture operation succeeded'
  [ ! -f "$TEST_ROOT/run.argv" ] || fail 'rejected operation launched Docker'
  [ ! -e "$(_transaction_lock_dir)" ] || fail 'rejected operation leaked its lock'
  assert_foreign_unchanged
  CASE_COUNT=$((CASE_COUNT + 1))
}

reset_case 'remove old immutable ID before output preparation'
start_capture --scope all --folder pcaps/selected >"$OUTPUT" 2>&1 || fail 'valid capture failed'
printf 'remove %s\nprepare\nverify\nrun\n' "$OLD_ID" >"$TEST_ROOT/expected"
cmp -s "$EVENTS" "$TEST_ROOT/expected" || fail 'replacement order changed'
[ -d "$CAPTURE_DIR/selected" ] || fail 'output missing'
[ ! -e "$(_transaction_lock_dir)" ] || fail 'successful capture leaked lock'
stop_capture >>"$OUTPUT" 2>&1 || fail 'stop failed'
[ ! -f "$CURRENT_ID" ] || fail 'stop left capture alive'
CASE_COUNT=$((CASE_COUNT + 1))

for failure in LIST_FAIL REMOVE_FAIL REMAIN_AFTER_REMOVE; do
  reset_case "refuse output mutation after $failure"
  printf -v "$failure" '%s' true
  assert_rejected start_capture --scope all --folder pcaps/missing/nested
  [ ! -e "$CAPTURE_DIR" ] || fail 'failed quiescence created capture root'
  [ "$(cat "$CURRENT_ID")" = "$OLD_ID" ] || fail 'failure lost old capture identity'
done

for folder in "$OUTSIDE" pcaps/tls-keys pcaps/tls-keys/child; do
  reset_case "preflight rejects $folder without removing old capture"
  assert_rejected start_capture --scope all --folder "$folder"
  [ ! -s "$EVENTS" ] || fail 'preflight rejection mutated runtime'
  [ ! -e "$CAPTURE_DIR" ] || fail 'preflight rejection created capture root'
done

for link_target in "$OUTSIDE" "$TEST_ROOT/missing-foreign"; do
  reset_case 'reject existing live or dangling output symlink'
  mkdir "$CAPTURE_DIR"
  ln -s "$link_target" "$CAPTURE_DIR/selected"
  assert_rejected start_capture --scope all --folder pcaps/selected/deep
  [ ! -s "$EVENTS" ] || fail 'existing link rejection removed old capture'
done

reset_case 'reject old writer final symlink before preparation'
mkdir -p "$CAPTURE_DIR/selected"
SWAP_ON_REMOVE=true
assert_rejected start_capture --scope all --folder pcaps/selected
[ ! -f "$CURRENT_ID" ] || fail 'old writer was not quiesced'

reset_case 'reject changed directory identity before Docker binding'
REPLACE_BEFORE_VERIFY=true
assert_rejected start_capture --scope all --folder pcaps/selected

reset_case 'failed stop preserves output and reports failure'
STOP_FAIL=true
assert_rejected stop_capture
[ "$(cat "$CURRENT_ID")" = "$OLD_ID" ] || fail 'failed stop removed capture'

for failure in DISABLE_FAIL RECREATE_FAIL; do
  reset_case "stop reports $failure instead of success"
  TLS_ENABLED=true
  printf -v "$failure" '%s' true
  assert_rejected stop_capture
  if grep -Fq 'TLS decrypt capture disabled' "$OUTPUT"; then fail 'failed disable/recreate reported success'; fi
done

# A real shared mutation lock prevents independent capture start/stop windows.
function hold_lock() {
  : >"$TEST_ROOT/ready"
  local release=""
  IFS= read -r release <"$TEST_ROOT/release"
  [ "$release" = release ]
}
reset_case 'concurrent start and stop cannot enter replacement window'
mkfifo "$TEST_ROOT/release"
(trap - EXIT; _capture_with_runtime_lock hold_lock) >"$TEST_ROOT/holder.log" 2>&1 &
HOLDER_PID=$!
attempt=0
while [ ! -f "$TEST_ROOT/ready" ] && [ "$attempt" -lt 100 ]; do sleep 0.05; attempt=$((attempt + 1)); done
[ -f "$TEST_ROOT/ready" ] || fail 'lock holder did not start'
for operation in start stop; do
  status=0
  if [ "$operation" = start ]; then
    start_capture --scope all --folder pcaps/selected >"$OUTPUT" 2>&1 || status=$?
  else stop_capture >"$OUTPUT" 2>&1 || status=$?; fi
  [ "$status" -ne 0 ] || fail "concurrent $operation passed the lock"
  grep -Fq 'Another mutating operation is in progress' "$OUTPUT" || fail 'missing lock diagnostic'
  [ ! -s "$EVENTS" ] || fail "concurrent $operation mutated runtime"
  [ ! -e "$CAPTURE_DIR" ] || fail 'concurrent start created output'
done
printf '%s\n' release >"$TEST_ROOT/release"
wait "$HOLDER_PID" || fail 'lock holder failed'
HOLDER_PID=""
[ ! -e "$(_transaction_lock_dir)" ] || fail 'holder leaked lock'
CASE_COUNT=$((CASE_COUNT + 1))

function interrupt_locked_command() {
  case "$1" in
  exit) exit 37 ;;
  term) local child_pid=""; child_pid="$(sh -c 'echo "$PPID"')"; kill -TERM "$child_pid"; exit 98 ;;
  esac
}
for interruption in exit term; do
  reset_case "release prep lock on $interruption and retain caller EXIT status"
  status=0
  (
    trap 'printf "%s\n" "$?" >"$TEST_ROOT/caller-exit"' EXIT
    _capture_with_runtime_lock interrupt_locked_command "$interruption"
  ) >"$OUTPUT" 2>&1 || status=$?
  expected=37
  [ "$interruption" != term ] || expected=143
  [ "$status" -eq "$expected" ] || fail 'interruption exit status changed'
  [ "$(cat "$TEST_ROOT/caller-exit")" = "$expected" ] || fail 'caller EXIT status changed'
  [ ! -e "$(_transaction_lock_dir)" ] || fail 'interruption leaked lock'
  CASE_COUNT=$((CASE_COUNT + 1))
done

"${BASH_UNDER_TEST:-bash}" "$ROOT_DIR/tests/capture_output_io.sh"
printf 'Capture bind-mount safety: %s shell cases passed.\n' "$CASE_COUNT"
COMPLETED=true
