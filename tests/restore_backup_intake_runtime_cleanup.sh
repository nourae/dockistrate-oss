#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-intake-runtime.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT
SELECTION="${DOCKISTRATE_RESTORE_RUNTIME_TEST_CASE:-all}"
PASSED=0

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "${CASE_DIR:-}/output" ] || cat "$CASE_DIR/output" >&2
  [ ! -f "${CASE_DIR:-}/restore-output" ] || cat "$CASE_DIR/restore-output" >&2
  exit 1
}

function assert_no_workspace() {
  local entry=""
  for entry in "$CASE_DIR/state/tmp"/restore_*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || fail_test 'accepted restore left a workspace after runtime preparation failed'
  done
  for entry in "$CASE_DIR/system-tmp"/dockistrate-domain.*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || fail_test 'accepted restore left a domain staging workspace after runtime preparation failed'
  done
}

function fingerprint_config() {
  python3 - "$CASE_DIR/state/config" <<'PY'
import hashlib
import os
import stat
import sys
root = sys.argv[1]
paths = [root]
for current, dirs, files in os.walk(root):
    paths.extend(os.path.join(current, name) for name in dirs + files)
for path in sorted(paths):
    metadata = os.lstat(path)
    digest = ""
    if stat.S_ISREG(metadata.st_mode):
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
    print(repr((path, metadata.st_dev, metadata.st_ino, metadata.st_mode,
                metadata.st_uid, metadata.st_gid, metadata.st_mtime_ns, digest)))
PY
}

function setup_case() {
  CASE_DIR="$TEST_DIR/$1"
  mkdir -p "$CASE_DIR/state/config" "$CASE_DIR/state/tmp" "$CASE_DIR/source/config" "$CASE_DIR/system-tmp"
  printf 'current\n' >"$CASE_DIR/state/config/marker.txt"
  printf 'archived\n' >"$CASE_DIR/source/config/marker.txt"
  chmod 640 "$CASE_DIR/state/config/marker.txt"
  fingerprint_config >"$CASE_DIR/before"
}

function assert_unchanged() {
  fingerprint_config >"$CASE_DIR/after"
  cmp -s "$CASE_DIR/before" "$CASE_DIR/after" || fail_test 'failed runtime preparation changed live configuration'
  assert_no_workspace
}

function passed() {
  PASSED=$((PASSED + 1))
  printf '[tests] PASS: %s\n' "$*"
}

case "$SELECTION" in all | decode)
  if (
    function require_valid_var_name() { [[ "${1:-}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; }
    # shellcheck source=../lib/backups/restore_intake.sh
    source "$ROOT_DIR/lib/backups/restore_intake.sh"
    trap - EXIT HUP INT TERM
    roundtrips=0
    for tested_signal in EXIT HUP INT TERM; do
      trap - "$tested_signal"
      default_declaration="$(trap -p "$tested_signal")"
      trap ':' "$tested_signal"
      _restore_intake_restore_trap '' "$tested_signal" || exit 71
      [ "$(trap -p "$tested_signal")" = "$default_declaration" ] || exit 72
      roundtrips=$((roundtrips + 1))
      trap ':' "$tested_signal"
      _restore_intake_restore_trap "$default_declaration" "$tested_signal" || exit 78
      [ "$(trap -p "$tested_signal")" = "$default_declaration" ] || exit 79
      roundtrips=$((roundtrips + 1))
      for tested_action in '' ':' "'" '"' '\' "''" $' \t\n \t\n' '# comment-only' \
        $'# single \' and double " quotes\n' \
        $'# backslash \\ and quote \\\' sequence\n' \
        $'# controls \r\t\033 and UTF-8 \303\251\n\n' \
        ': "$(printf executed >>"$TEST_DIR/decode-executed")"' \
        $'printf "%s\\n" \'literal $() and `backticks`\'\n# final comment\n'; do
        trap -- "$tested_action" "$tested_signal"
        declaration="$(trap -p "$tested_signal")"
        # Model the nonempty supervision action. Bash itself loses an ignored
        # EXIT declaration when a function restores it after a default reset.
        trap ':' "$tested_signal"
        decoded=not-decoded
        _restore_intake_trap_action decoded "$declaration" "$tested_signal" || exit 73
        [ "$decoded" = "$tested_action" ] || exit 74
        _restore_intake_restore_trap "$declaration" "$tested_signal" || exit 75
        restored_declaration="$(trap -p "$tested_signal")"
        trap ':' "$tested_signal"
        [ "$restored_declaration" = "$declaration" ] || exit 76
        [ ! -e "$TEST_DIR/decode-executed" ] || exit 77
        roundtrips=$((roundtrips + 1))
      done
      trap - "$tested_signal"
    done
    printf '%s\n' "$roundtrips" >"$TEST_DIR/decoded-cases"
  ); then
    passed "exact trap decoding and restoration for $(cat "$TEST_DIR/decoded-cases") default, empty and quoted actions"
  else
    fail_test 'trap capture, decoding or restoration changed literal action bytes'
  fi
  ;;
esac

case "$SELECTION" in all | cli)
  for cli_kind in access-denied default-term; do
    setup_case "cli-$cli_kind"
    cp "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$CASE_DIR/"
    cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$CASE_DIR/"
    mkdir "$CASE_DIR/bin"
    cat >"$CASE_DIR/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_TRACE"
case "${1:-}" in
info) exit 0 ;;
ps)
  [ "$DOCKER_CASE" != default-term ] || kill -TERM "$PPID"
  exit 1
  ;;
*) exit 97 ;;
esac
SHIM
    chmod 700 "$CASE_DIR/bin/docker"
    status=0
    PATH="$CASE_DIR/bin:$PATH" TMPDIR="$CASE_DIR/system-tmp" DOCKER_TRACE="$CASE_DIR/docker.trace" DOCKER_CASE="$cli_kind" SKIP_DOCKER_CHECKS=false \
      "$BASH" "$CASE_DIR/dockistrate.sh" restore-backup "$CASE_DIR/source" >"$CASE_DIR/output" 2>&1 || status=$?
    expected_status=1
    [ "$cli_kind" != default-term ] || expected_status=143
    [ "$status" -eq "$expected_status" ] || fail_test "Docker $cli_kind returned unexpected status $status"
    [ "$(cat "$CASE_DIR/docker.trace")" = $'info\nps' ] || fail_test 'CLI did not reach the real Docker access check after intake'
    if [ "$cli_kind" = access-denied ]; then
      grep -Fq 'Unable to execute Docker commands' "$CASE_DIR/output" || fail_test 'CLI omitted the dependency failure'
    fi
    assert_unchanged
    passed "real CLI cleans accepted snapshot after Docker $cli_kind"
  done
  ;;
esac

cat >"$TEST_DIR/case.sh" <<'CASE'
#!/usr/bin/env bash
# shellcheck disable=SC2034 # Runtime settings are consumed by sourced modules.
set -Eeuo pipefail
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backups.sh"
BASE_DIR="$CASE_DIR"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
SKIP_DOCKER_CHECKS=true
DOCKISTRATE_RUNTIME_PREPARED=false

function record_event() { printf '%s\n' "$*" >>"$CASE_DIR/events"; }
function confirm_prompt() { return 0; }
function audit_log() { :; }
function _run_command_audit_message() { :; }
function caller_exit() {
  local status="$1" entry="" workspace=clean
  for entry in "$TMP_DIR"/restore_*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || workspace=leaked
  done
  record_event "exit:$status:$workspace"
}
function dockistrate_prepare_runtime() {
  local entry="" admitted=false
  for entry in "$TMP_DIR"/restore_*/directory/config/marker.txt; do
    [ ! -f "$entry" ] || admitted=true
  done
  [ "$admitted" = true ] || exit 91
  [ ! -e "$CASE_DIR/exit-text" ] || exit 98
  printf 'prepared\n' >"$CASE_DIR/prepared"
  case "$CASE_KIND" in
  exit-one) exit 1 ;;
  exit-seven | quoted-exit | comment-exit | whitespace-exit | slash-exit | heredoc-exit) exit 7 ;;
  term-exit | term-return | default-term | ignored-term) kill -TERM "$$" ;;
  default-hup) kill -HUP "$$" ;;
  default-int) kill -INT "$$" ;;
  success | quoted-success) DOCKISTRATE_RUNTIME_PREPARED=true; return 0 ;;
  esac
  return 1
}
function begin_transaction() {
  [ "$DOCKISTRATE_RUNTIME_PREPARED" = true ] || exit 92
  [ "$(trap -p HUP INT TERM ERR EXIT)" = "$saved_traps" ] || exit 93
  printf 'transaction\n' >"$CASE_DIR/transaction"
  return 1
}

trap 'record_event caller-hup' HUP
trap 'record_event caller-int' INT
trap 'record_event caller-term' TERM
trap 'record_event caller-err' ERR
trap 'caller_exit "$?"' EXIT
case "$CASE_KIND" in
term-exit) trap 'record_event caller-term; exit 143' TERM ;;
default-term) trap - TERM ;;
default-hup) trap - HUP ;;
default-int) trap - INT ;;
ignored-term) trap '' TERM ;;
no-exit) trap - EXIT ;;
ignored-exit) trap '' EXIT ;;
comment-*) trap '# An action containing only a comment.' EXIT ;;
whitespace-*) trap $' \t\n \t\n' EXIT ;;
slash-*)
  IFS= read -r -d '' slash_exit <<'TRAP_ACTION' || true
caller_exit "$?"
exec 9>>"$CASE_DIR/exit-text"
printf '%s\n' >&9 tail\
TRAP_ACTION
  # Preserve an unquoted backslash at the original action's exact EOF.
  trap "${slash_exit%$'\n'}" EXIT
  ;;
heredoc-*)
  IFS= read -r -d '' heredoc_exit <<'TRAP_ACTION' || true
caller_exit "$?"
cat >>"$CASE_DIR/exit-text" <<'END\'
literal heredoc body with "quotes", $substitutions and \backslashes
END\
TRAP_ACTION
  # The delimiter's backslash is literal, and its final byte is exactly EOF.
  trap "${heredoc_exit%$'\n'}" EXIT
  ;;
quoted-*)
  # Keep all quoting literal, including the final newline. Decoding a trap
  # declaration must not execute its substitutions or alter any source byte.
  IFS= read -r -d '' quoted_exit <<'TRAP_ACTION' || true
caller_exit "$?"
printf '%s\n' "double \"quoted\"" 'single '\''quoted' 'backslash \ literal' \
  'literal $(do_not_run) and `do_not_run`' >>"$CASE_DIR/exit-text"
printf '%s\n' "$(printf substitution)" >>"$CASE_DIR/exit-text"
# Retain this trailing newline and these literal characters: ' \ "
TRAP_ACTION
  trap "$quoted_exit" EXIT
  ;;
esac
if [ "${CASE_NATIVE_TRAP:-false}" = true ]; then
  exit "${CASE_NATIVE_STATUS:-0}"
fi
saved_traps="$(trap -p HUP INT TERM ERR EXIT)"
saved_options="$-"
umask 027
saved_umask="$(umask)"
status=0
restore_backup "$CASE_DIR/source" >"$CASE_DIR/restore-output" 2>&1 || status=$?
[ "$status" -eq 1 ] || exit 94
[ "$(trap -p HUP INT TERM ERR EXIT)" = "$saved_traps" ] || exit 95
[ "$-" = "$saved_options" ] || exit 96
[ "$(umask)" = "$saved_umask" ] || exit 97
printf 'returned\n' >"$CASE_DIR/returned"
CASE

function run_case() {
  local kind="$1" expected_status="$2" expected_events="$3" status=0 actual_events="" native_status=0
  setup_case "$kind"
  ROOT_DIR="$ROOT_DIR" CASE_DIR="$CASE_DIR" CASE_KIND="$kind" \
    "$BASH" "$TEST_DIR/case.sh" >"$CASE_DIR/output" 2>&1 || status=$?
  [ "$status" -eq "$expected_status" ] || fail_test "$kind returned $status instead of $expected_status"
  [ -f "$CASE_DIR/prepared" ] || fail_test "$kind did not reach runtime preparation with an accepted snapshot"
  actual_events="$(cat "$CASE_DIR/events" 2>/dev/null || true)"
  [ "$actual_events" = "$expected_events" ] || fail_test "$kind changed caller trap behavior or exit status: $actual_events"
  case "$kind" in
  exit-* | quoted-exit | comment-exit | whitespace-exit | slash-exit | heredoc-exit | term-exit | default-*)
    [ ! -e "$CASE_DIR/returned" ] || fail_test "$kind unexpectedly returned from explicit exit" ;;
  *) [ -f "$CASE_DIR/returned" ] || fail_test "$kind failed to restore caller shell state" ;;
  esac
  if [ "$kind" = success ] || [ "$kind" = quoted-success ]; then
    [ -f "$CASE_DIR/transaction" ] || fail_test 'runtime globals did not survive successful preparation'
  else
    [ ! -e "$CASE_DIR/transaction" ] || fail_test "$kind reached the transaction after failed preparation"
  fi
  case "$kind" in quoted-*)
    cat >"$CASE_DIR/expected-exit-text" <<'EXPECTED'
double "quoted"
single 'quoted
backslash \ literal
literal $(do_not_run) and `do_not_run`
substitution
EXPECTED
    cmp -s "$CASE_DIR/expected-exit-text" "$CASE_DIR/exit-text" || fail_test "$kind changed the saved trap's quoted or multiline action"
    ;;
  slash-* | heredoc-*)
    # Match native interpretation at the original action's exact EOF. Bash
    # versions differ for bare backslashes; heredoc delimiters remain literal.
    mkdir "$CASE_DIR/native"
    ROOT_DIR="$ROOT_DIR" CASE_DIR="$CASE_DIR/native" CASE_KIND="$kind" \
      CASE_NATIVE_TRAP=true CASE_NATIVE_STATUS="$expected_status" \
      "$BASH" "$TEST_DIR/case.sh" >"$CASE_DIR/native/output" 2>&1 || native_status=$?
    [ "$native_status" -eq "$expected_status" ] || fail_test "$kind native control returned an unexpected status"
    cmp -s "$CASE_DIR/native/exit-text" "$CASE_DIR/exit-text" || fail_test "$kind changed the current shell's native action at EOF"
    ;;
  esac
  assert_unchanged
  passed "runtime $kind preserves caller behavior and cleans accepted snapshot"
}

case "$SELECTION" in all | traps)
  run_case return-one 0 'exit:0:clean'
  run_case exit-one 1 'exit:1:clean'
  run_case exit-seven 7 'exit:7:clean'
  run_case success 0 'exit:0:clean'
  run_case term-exit 143 $'caller-term\nexit:143:clean'
  run_case term-return 0 $'caller-term\nexit:0:clean'
  run_case default-term 143 'exit:143:clean'
  run_case default-hup 129 'exit:129:clean'
  run_case default-int 130 'exit:130:clean'
  run_case ignored-term 0 'exit:0:clean'
  run_case no-exit 0 ''
  run_case ignored-exit 0 ''
  run_case quoted-return 0 'exit:0:clean'
  run_case quoted-success 0 'exit:0:clean'
  run_case quoted-exit 7 'exit:7:clean'
  run_case comment-return 0 ''
  run_case comment-exit 7 ''
  run_case whitespace-return 0 ''
  run_case whitespace-exit 7 ''
  run_case slash-return 0 'exit:0:clean'
  run_case slash-exit 7 'exit:7:clean'
  ;;
esac

case "$SELECTION" in all | traps | heredoc)
  run_case heredoc-return 0 'exit:0:clean'
  run_case heredoc-exit 7 'exit:7:clean'
  ;;
esac

[ "$PASSED" -gt 0 ] || fail_test "unknown runtime cleanup test selection: $SELECTION"
printf '[tests] restore_backup_intake_runtime_cleanup.sh: PASS (%s cases)\n' "$PASSED"
