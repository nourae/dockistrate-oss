#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-intake-signals.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
CURRENT_CASE_PID=""
CURRENT_WORKER_GROUP=""

function cleanup() {
  if [ -n "$CURRENT_WORKER_GROUP" ]; then
    kill -KILL -- "-$CURRENT_WORKER_GROUP" 2>/dev/null || true
  fi
  if [ -n "$CURRENT_CASE_PID" ]; then
    kill -KILL "$CURRENT_CASE_PID" 2>/dev/null || true
    wait "$CURRENT_CASE_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "${CASE_DIR:-}/output" ] || cat "$CASE_DIR/output" >&2
  exit 1
}

cat >"$TEST_DIR/case.sh" <<'CASE'
#!/usr/bin/env bash
set -Eeuo pipefail

function require_valid_var_name() {
  [[ "${1:-}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}
function _backup_remove_private_restore_dir() {
  [ "$1" = "$CASE_DIR/workspace" ] || return 1
  rm -rf "$1"
}
source "$ROOT_DIR/lib/backups/restore_intake.sh"

function _restore_intake_archive() {
  local workspace="$2" process_id="" group=""
  if [ "$CASE_KIND" = success ] || [ "$CASE_KIND" = result-signal ]; then
    mkdir -p "$workspace/extracted/payload"
    printf 'fixture\n' >"$workspace/extracted/payload/canary"
    return 0
  elif [ "$CASE_KIND" = failure ]; then
    return 1
  fi
  process_id="$(sh -c 'printf "%s\n" "$PPID"')"
  group="$(ps -o pgid= -p "$process_id")"
  group="${group//[[:space:]]/}"
  printf '%s\n' "$group" >"$CASE_DIR/worker_group"
  # This is a real foreground producer pipeline inside the actual intake
  # worker. The stubborn variant verifies bounded escalation and parent cleanup.
  if [ "$CASE_KIND" = stubborn ]; then
    (
      trap '' TERM
      : >"$CASE_DIR/ready"
      sleep 30
    ) | cat >"$workspace/producer"
  else
    (
      : >"$CASE_DIR/ready"
      sleep 30
    ) | cat >"$workspace/producer"
  fi
}

# These actions must round-trip byte-for-byte through temporary supervision.
# Include physical/trailing newlines, both quote styles and literal shell text.
IFS= read -r -d '' signal_action <<'SIGNAL_ACTION' || true
printf '%s\n' "caller-__SIGNAL__" >>"$CASE_DIR/caller_events"
: 'single '\'' quote, backslash \, double ", literal $(do_not_run) `do_not_run`'
# Keep this final newline.
SIGNAL_ACTION
trap "${signal_action/__SIGNAL__/hup}" HUP
trap "${signal_action/__SIGNAL__/int}" INT
trap "${signal_action/__SIGNAL__/term}" TERM
trap 'printf "caller-err\n" >>"$CASE_DIR/caller_events"' ERR
trap 'printf "caller-exit\n" >>"$CASE_DIR/caller_events"' EXIT
[ "$CASE_MONITOR" != on ] || set -m
saved_traps="$(trap -p HUP INT TERM ERR EXIT)"
saved_options="$-"
umask 027
saved_umask="$(umask)"
mkdir "$CASE_DIR/workspace"
accepted=""
if [ "$CASE_KIND" = result-signal ]; then
  # Deliver TERM after the parent reads the completed result but before stage
  # decides whether to publish it. This used to return success or retain it.
  function read() {
    local result=0 argument=""
    if builtin read "$@"; then result=0; else result=$?; fi
    for argument in "$@"; do
      [ "$argument" != staged_result ] || kill -TERM "$$"
    done
    return "$result"
  }
fi
if _restore_intake_stage accepted "$CASE_DIR/input.tar.gz" "$CASE_DIR/workspace" 1024 1024 10; then
  status=0
else
  status=$?
fi
[ "$(trap -p HUP INT TERM ERR EXIT)" = "$saved_traps" ] || exit 81
[ "$-" = "$saved_options" ] || exit 82
[ "$(umask)" = "$saved_umask" ] || exit 83
[ ! -s "$CASE_DIR/caller_events" ] || exit 84
if [ "$CASE_KIND" = success ]; then
  [ "$status" -eq 0 ] && [ "$accepted" = "$CASE_DIR/workspace/extracted/payload" ] || exit 85
  [ "$(cat "$accepted/canary")" = fixture ] || exit 86
  _restore_intake_cleanup "$CASE_DIR/workspace"
else
  [ "$status" -eq "$CASE_EXPECTED" ] || exit 87
  [ ! -e "$CASE_DIR/workspace" ] && [ -z "$accepted" ] || exit 88
fi
printf '%s\n' "$status" >"$CASE_DIR/status"
CASE

function run_case() {
  local name="$1" kind="$2" monitor="$3" signal_name="${4:-}" signal_target="${5:-pid}"
  local expected=0 idx=0 status=0 actual_group="" previous_monitor=false
  CASE_DIR="$TEST_DIR/$name"
  mkdir "$CASE_DIR"
  : >"$CASE_DIR/input.tar.gz"
  case "$signal_name" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
  [ "$kind" != failure ] || expected=1
  [ "$kind" != result-signal ] || expected=143
  export ROOT_DIR CASE_DIR
  export CASE_KIND="$kind" CASE_MONITOR="$monitor" CASE_EXPECTED="$expected"
  case "$-" in *m*) previous_monitor=true ;; esac
  # Launching with job control avoids inherited ignored SIGINT in the test
  # subprocess and gives group-signal tests a group owned only by this case.
  set -m
  "$BASH" "$TEST_DIR/case.sh" >"$CASE_DIR/output" 2>&1 &
  CURRENT_CASE_PID=$!
  [ "$previous_monitor" = true ] || set +m
  if [ -n "$signal_name" ]; then
    for ((idx = 0; idx < 250; idx++)); do
      [ ! -f "$CASE_DIR/ready" ] || break
      kill -0 "$CURRENT_CASE_PID" 2>/dev/null || break
      sleep 0.02
    done
    [ -f "$CASE_DIR/ready" ] || fail_test "$name did not start its intake producer"
    CURRENT_WORKER_GROUP="$(cat "$CASE_DIR/worker_group")"
    case "$CURRENT_WORKER_GROUP" in '' | *[!0-9]*) fail_test "$name did not record a process group" ;; esac
    [ "$CURRENT_WORKER_GROUP" != "$CURRENT_CASE_PID" ] || fail_test "$name did not isolate its intake worker"
    if [ "$signal_target" = group ]; then
      actual_group="$(ps -o pgid= -p "$CURRENT_CASE_PID")"
      actual_group="${actual_group//[[:space:]]/}"
      [ "$actual_group" = "$CURRENT_CASE_PID" ] || fail_test 'test caller process group is not owned'
      kill -s "$signal_name" -- "-$CURRENT_CASE_PID"
    else
      kill -s "$signal_name" "$CURRENT_CASE_PID"
    fi
  fi
  for ((idx = 0; idx < 300; idx++)); do
    kill -0 "$CURRENT_CASE_PID" 2>/dev/null || break
    sleep 0.02
  done
  kill -0 "$CURRENT_CASE_PID" 2>/dev/null && fail_test "$name did not finish within the cancellation deadline"
  if wait "$CURRENT_CASE_PID"; then status=0; else status=$?; fi
  CURRENT_CASE_PID=""
  [ "$status" -eq 0 ] || fail_test "$name failed with child status $status"
  [ "$(cat "$CASE_DIR/status")" = "$expected" ] || fail_test "$name returned the wrong intake status"
  [ "$(cat "$CASE_DIR/caller_events")" = caller-exit ] || fail_test "$name changed or invoked caller traps"
  if [ -n "$CURRENT_WORKER_GROUP" ]; then
    # Orphan zombies can briefly await the CI init's reaper; they cannot keep
    # producers running or open files. Assert there are no living group members.
    if ps -eo pgid=,stat= | awk -v group="$CURRENT_WORKER_GROUP" '$1 == group && $2 !~ /^Z/ { found=1 } END { exit !found }'; then
      fail_test "$name left a living intake process"
    fi
  fi
  CURRENT_WORKER_GROUP=""
}

run_case success-monitor-off success off
run_case success-monitor-on success on
run_case failure-monitor-off failure off
run_case failure-monitor-on failure on
run_case term-during-result-read result-signal off
run_case hup-pid paused off HUP
run_case int-pid paused off INT
run_case term-pid paused off TERM
run_case term-monitor-on paused on TERM
run_case term-caller-group paused off TERM group
run_case term-stubborn-producer stubborn off TERM

printf '[tests] restore_backup_intake_signals.sh: PASS\n'
