#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox.XXXXXX")"
TRAP_TEST_ROOT=""
PID_TEST_ROOT=""
SYMLINK_TEST_ROOT=""
RACE_LOCK_ROOT=""
STALE_LOCK_ROOT=""
FIFO_LOCK_ROOT=""
LIVE_LOCK_ROOT=""
EPERM_LOCK_ROOT=""
DEAD_LOCK_ROOT=""

# shellcheck source=tests/lib/state_sandbox.sh
source "${REPO_ROOT}/tests/lib/state_sandbox.sh"

unset DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER

function cleanup() {
  dockistrate_test_state_sandbox_restore
  rm -rf "$SANDBOX_ROOT"
  if [ -n "${TRAP_TEST_ROOT:-}" ]; then
    rm -rf "$TRAP_TEST_ROOT"
  fi
  if [ -n "${PID_TEST_ROOT:-}" ]; then
    rm -rf "$PID_TEST_ROOT"
  fi
  if [ -n "${SYMLINK_TEST_ROOT:-}" ]; then
    rm -rf "$SYMLINK_TEST_ROOT"
  fi
  if [ -n "${RACE_LOCK_ROOT:-}" ]; then
    rm -rf "$RACE_LOCK_ROOT"
  fi
  if [ -n "${STALE_LOCK_ROOT:-}" ]; then
    rm -rf "$STALE_LOCK_ROOT"
  fi
  if [ -n "${FIFO_LOCK_ROOT:-}" ]; then
    rm -rf "$FIFO_LOCK_ROOT"
  fi
  if [ -n "${LIVE_LOCK_ROOT:-}" ]; then
    rm -rf "$LIVE_LOCK_ROOT"
  fi
  if [ -n "${EPERM_LOCK_ROOT:-}" ]; then
    rm -rf "$EPERM_LOCK_ROOT"
  fi
  if [ -n "${DEAD_LOCK_ROOT:-}" ]; then
    rm -rf "$DEAD_LOCK_ROOT"
  fi
}
trap cleanup EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

mkdir -p "${SANDBOX_ROOT}/state/config"
printf '%s\n' "keep-me" >"${SANDBOX_ROOT}/state/config/operator-sentinel.txt"

dockistrate_test_state_sandbox "$SANDBOX_ROOT" || fail_test "state sandbox setup failed"
dockistrate_test_state_sandbox "$SANDBOX_ROOT" || fail_test "state sandbox should be idempotent"

if [ -e "${SANDBOX_ROOT}/state/config/operator-sentinel.txt" ]; then
  fail_test "active sandbox should start with a clean state directory"
fi

mkdir -p "${SANDBOX_ROOT}/state/config"
printf '%s\n' "bad_header" >"${SANDBOX_ROOT}/state/config/backend_ports.csv"
printf '%s\n' "temporary" >"${SANDBOX_ROOT}/state/transient-test-file"

dockistrate_test_state_sandbox_restore

if [ "$(cat "${SANDBOX_ROOT}/state/config/operator-sentinel.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_test "state sandbox did not restore the original sentinel"
fi
if [ -e "${SANDBOX_ROOT}/state/transient-test-file" ]; then
  fail_test "state sandbox left transient active-state data behind"
fi
if [ -e "${SANDBOX_ROOT}/state/config/backend_ports.csv" ]; then
  fail_test "state sandbox left corrupted backend_ports.csv behind"
fi

TRAP_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_trap.XXXXXX")"
mkdir -p "${TRAP_TEST_ROOT}/repo/state/config"
printf '%s\n' "keep-me" >"${TRAP_TEST_ROOT}/repo/state/config/operator-sentinel.txt"
(
  function child_cleanup() {
    dockistrate_test_state_sandbox_restore
    printf '%s\n' "ran" >"${TRAP_TEST_ROOT}/caller-trap-ran"
  }
  trap child_cleanup EXIT
  dockistrate_test_state_sandbox "${TRAP_TEST_ROOT}/repo" || fail_test "child sandbox setup failed"
)
if [ "$(cat "${TRAP_TEST_ROOT}/caller-trap-ran" 2>/dev/null || true)" != "ran" ]; then
  fail_test "state sandbox overwrote the caller's EXIT trap"
fi
if [ "$(cat "${TRAP_TEST_ROOT}/repo/state/config/operator-sentinel.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_test "caller-trap sandbox did not restore the original state"
fi
rm -rf "$TRAP_TEST_ROOT"
TRAP_TEST_ROOT=""

PID_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_pid.XXXXXX")"
mkdir -p "${PID_TEST_ROOT}/repo/state/config"
printf '%s\n' "keep-me" >"${PID_TEST_ROOT}/repo/state/config/operator-sentinel.txt"
(
  dockistrate_test_state_sandbox "${PID_TEST_ROOT}/repo" || fail_test "pid sandbox setup failed"
  dockistrate_test_state_sandbox_write_lock_pid "${PID_TEST_ROOT}/holder-pid"
  if [ -L "${PID_TEST_ROOT}/repo/tmp/tests-state-sandbox.lock" ]; then
    readlink "${PID_TEST_ROOT}/repo/tmp/tests-state-sandbox.lock" >"${PID_TEST_ROOT}/lock-pid"
  else
    cp "${PID_TEST_ROOT}/repo/tmp/tests-state-sandbox.lock/pid" "${PID_TEST_ROOT}/lock-pid"
  fi
  dockistrate_test_state_sandbox_restore
)
if ! cmp -s "${PID_TEST_ROOT}/holder-pid" "${PID_TEST_ROOT}/lock-pid"; then
  fail_test "state sandbox lock pid did not match the lock-holder shell"
fi
if [ "$(cat "${PID_TEST_ROOT}/repo/state/config/operator-sentinel.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_test "pid sandbox did not restore the original state"
fi
rm -rf "$PID_TEST_ROOT"
PID_TEST_ROOT=""

SYMLINK_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_symlink.XXXXXX")"
mkdir -p "${SYMLINK_TEST_ROOT}/target"
printf '%s\n' "keep-me" >"${SYMLINK_TEST_ROOT}/target/keep.txt"
ln -s "${SYMLINK_TEST_ROOT}/target" "${SYMLINK_TEST_ROOT}/link"
(
  function rm() {
    if [ "$#" -ge 2 ] && [ "$1" = "-rf" ] && [ "$2" = "${SYMLINK_TEST_ROOT}/link" ]; then
      return 1
    fi
    command rm "$@"
  }
  dockistrate_test_remove_dir_tree "${SYMLINK_TEST_ROOT}/link" || fail_test "state sandbox failed to remove symlink path"
)
if [ -L "${SYMLINK_TEST_ROOT}/link" ] || [ -e "${SYMLINK_TEST_ROOT}/link" ]; then
  fail_test "state sandbox left symlink path behind"
fi
if [ "$(cat "${SYMLINK_TEST_ROOT}/target/keep.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_test "state sandbox followed symlink target during cleanup"
fi
rm -rf "$SYMLINK_TEST_ROOT"
SYMLINK_TEST_ROOT=""

RACE_LOCK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_lock_race.XXXXXX")"
mkdir -p "${RACE_LOCK_ROOT}/tmp"
ln -s "$$" "${RACE_LOCK_ROOT}/tmp/tests-state-sandbox.lock"
dockistrate_test_state_sandbox_reclaim_stale_lock "${RACE_LOCK_ROOT}/tmp/tests-state-sandbox.lock" "999999" || fail_test "state sandbox stale-lock revalidation failed"
if [ "$(readlink "${RACE_LOCK_ROOT}/tmp/tests-state-sandbox.lock" 2>/dev/null || true)" != "$$" ]; then
  fail_test "state sandbox removed a lock whose pid changed before stale cleanup"
fi
rm -rf "$RACE_LOCK_ROOT"
RACE_LOCK_ROOT=""

STALE_LOCK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_lock.XXXXXX")"
mkdir -p "${STALE_LOCK_ROOT}/tmp/tests-state-sandbox.lock"
mkdir -p "${STALE_LOCK_ROOT}/state/config"
printf '%s\n' "keep-me" >"${STALE_LOCK_ROOT}/state/config/operator-sentinel.txt"
DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_RETRIES=1 dockistrate_test_state_sandbox "$STALE_LOCK_ROOT" || fail_test "state sandbox did not recover a stale lock without a pid"
if [ ! -L "${STALE_LOCK_ROOT}/tmp/tests-state-sandbox.lock" ]; then
  fail_test "state sandbox stale directory lock was not replaced with a symlink lock"
fi
dockistrate_test_state_sandbox_restore
if [ -e "${STALE_LOCK_ROOT}/tmp/tests-state-sandbox.lock" ]; then
  fail_test "state sandbox left a stale lock after recovery"
fi
if [ "$(cat "${STALE_LOCK_ROOT}/state/config/operator-sentinel.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_test "stale-lock sandbox did not restore the original state"
fi
rm -rf "$STALE_LOCK_ROOT"
STALE_LOCK_ROOT=""

FIFO_LOCK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_fifo_lock.XXXXXX")"
mkdir -p "${FIFO_LOCK_ROOT}/tmp/tests-state-sandbox.lock"
mkdir -p "${FIFO_LOCK_ROOT}/state/config"
printf '%s\n' "keep-me" >"${FIFO_LOCK_ROOT}/state/config/operator-sentinel.txt"
if command -v mkfifo >/dev/null 2>&1; then
  mkfifo "${FIFO_LOCK_ROOT}/tmp/tests-state-sandbox.lock/pid"
  DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_RETRIES=1 dockistrate_test_state_sandbox "$FIFO_LOCK_ROOT" || fail_test "state sandbox did not recover a stale lock with a FIFO pid"
  if [ ! -L "${FIFO_LOCK_ROOT}/tmp/tests-state-sandbox.lock" ]; then
    fail_test "state sandbox FIFO pid lock was not replaced with a symlink lock"
  fi
  dockistrate_test_state_sandbox_restore
  if [ -e "${FIFO_LOCK_ROOT}/tmp/tests-state-sandbox.lock" ]; then
    fail_test "state sandbox left a FIFO pid lock after recovery"
  fi
  if [ "$(cat "${FIFO_LOCK_ROOT}/state/config/operator-sentinel.txt" 2>/dev/null || true)" != "keep-me" ]; then
    fail_test "FIFO pid sandbox did not restore the original state"
  fi
else
  echo "state_sandbox_restore.sh: skipping FIFO pid lock regression because mkfifo is unavailable"
fi
rm -rf "$FIFO_LOCK_ROOT"
FIFO_LOCK_ROOT=""

LIVE_LOCK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_live_lock.XXXXXX")"
mkdir -p "${LIVE_LOCK_ROOT}/tmp/tests-state-sandbox.lock"
printf '%s\n' "$$" >"${LIVE_LOCK_ROOT}/tmp/tests-state-sandbox.lock/pid"
mkdir -p "${LIVE_LOCK_ROOT}/state/config"
printf '%s\n' "keep-me" >"${LIVE_LOCK_ROOT}/state/config/operator-sentinel.txt"
if DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_RETRIES=1 dockistrate_test_state_sandbox "$LIVE_LOCK_ROOT" >/dev/null 2>&1; then
  fail_test "state sandbox acquired a live directory lock"
fi
if [ "$(cat "${LIVE_LOCK_ROOT}/tmp/tests-state-sandbox.lock/pid" 2>/dev/null || true)" != "$$" ]; then
  fail_test "state sandbox modified a live directory lock pid"
fi
if find "${LIVE_LOCK_ROOT}/tmp/tests-state-sandbox.lock" -mindepth 1 -maxdepth 1 -type l | grep -q .; then
  fail_test "state sandbox created a nested symlink inside a live directory lock"
fi
if [ "$(cat "${LIVE_LOCK_ROOT}/state/config/operator-sentinel.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_test "live-lock sandbox attempt modified repo state"
fi
rm -rf "$LIVE_LOCK_ROOT"
LIVE_LOCK_ROOT=""

DEAD_LOCK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_dead_lock.XXXXXX")"
mkdir -p "${DEAD_LOCK_ROOT}/tmp"
dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null || ps -p "$dead_pid" >/dev/null 2>&1; do
  dead_pid=$((dead_pid + 1))
done
(
  function python3() {
    return 127
  }
  function python() {
    return 127
  }
  function perl() {
    return 127
  }

  dockistrate_test_state_sandbox_lock_pid_is_reclaimable "$dead_pid" || fail_test "dead-pid lock should be reclaimable without interpreter probes"
)
ln -s "$dead_pid" "${DEAD_LOCK_ROOT}/tmp/tests-state-sandbox.lock"
mkdir -p "${DEAD_LOCK_ROOT}/state/config"
printf '%s\n' "keep-me" >"${DEAD_LOCK_ROOT}/state/config/operator-sentinel.txt"
DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_RETRIES=1 dockistrate_test_state_sandbox "$DEAD_LOCK_ROOT" || fail_test "state sandbox did not recover a dead-pid symlink lock"
if [ ! -L "${DEAD_LOCK_ROOT}/tmp/tests-state-sandbox.lock" ]; then
  fail_test "state sandbox dead-pid lock was not replaced with a symlink lock"
fi
if [ "$(readlink "${DEAD_LOCK_ROOT}/tmp/tests-state-sandbox.lock" 2>/dev/null || true)" = "$dead_pid" ]; then
  fail_test "state sandbox kept the dead-pid lock target after recovery"
fi
dockistrate_test_state_sandbox_restore
if [ "$(cat "${DEAD_LOCK_ROOT}/state/config/operator-sentinel.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_test "dead-pid sandbox did not restore the original state"
fi
rm -rf "$DEAD_LOCK_ROOT"
DEAD_LOCK_ROOT=""

EPERM_LOCK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_state_sandbox_eperm_lock.XXXXXX")"
mkdir -p "${EPERM_LOCK_ROOT}/tmp/tests-state-sandbox.lock"
printf '%s\n' "$$" >"${EPERM_LOCK_ROOT}/tmp/tests-state-sandbox.lock/pid"
mkdir -p "${EPERM_LOCK_ROOT}/state/config"
printf '%s\n' "keep-me" >"${EPERM_LOCK_ROOT}/state/config/operator-sentinel.txt"
(
  function kill() {
    if [ "$#" -eq 2 ] && [ "$1" = "-0" ] && [ "$2" = "$$" ]; then
      return 1
    fi
    command kill "$@"
  }
  function ps() {
    if [ "$#" -ge 2 ] && [ "$1" = "-p" ] && [ "$2" = "$$" ]; then
      return 1
    fi
    command ps "$@"
  }
  function python3() {
    return 0
  }
  function python() {
    return 0
  }

  if DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_RETRIES=1 dockistrate_test_state_sandbox "$EPERM_LOCK_ROOT" >/dev/null 2>&1; then
    fail_test "state sandbox acquired an inaccessible live directory lock"
  fi
)
if [ "$(cat "${EPERM_LOCK_ROOT}/tmp/tests-state-sandbox.lock/pid" 2>/dev/null || true)" != "$$" ]; then
  fail_test "state sandbox modified an inaccessible live directory lock pid"
fi
if find "${EPERM_LOCK_ROOT}/tmp/tests-state-sandbox.lock" -mindepth 1 -maxdepth 1 -type l | grep -q .; then
  fail_test "state sandbox created a nested symlink inside an inaccessible live directory lock"
fi
if [ "$(cat "${EPERM_LOCK_ROOT}/state/config/operator-sentinel.txt" 2>/dev/null || true)" != "keep-me" ]; then
  fail_test "inaccessible-live-lock sandbox attempt modified repo state"
fi
rm -rf "$EPERM_LOCK_ROOT"
EPERM_LOCK_ROOT=""

echo "state_sandbox_restore.sh: PASS"
