# shellcheck shell=bash

function dockistrate_test_remove_dir_tree() {
  local dir="${1:-}" attempt=1
  [ -n "$dir" ] || return 1

  while [ "$attempt" -le 3 ]; do
    rm -rf "$dir" 2>/dev/null || true
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
      return 0
    fi

    if [ -L "$dir" ]; then
      rm -f "$dir" 2>/dev/null || true
      if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        return 0
      fi
    elif [ -d "$dir" ]; then
      find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
      rmdir "$dir" 2>/dev/null || true
      if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        return 0
      fi
    fi

    attempt=$((attempt + 1))
    sleep 1 2>/dev/null || true
  done

  echo "[tests] Error: failed to remove ${dir}" >&2
  return 1
}

function dockistrate_test_state_sandbox_read_lock_pid() {
  local pid_file="${1:-}" lock_pid=""

  if [ -n "$pid_file" ] && [ -L "$pid_file" ]; then
    lock_pid="$(readlink "$pid_file" 2>/dev/null || true)"
  elif [ -n "$pid_file" ] && [ -f "${pid_file}/pid" ] && [ -r "${pid_file}/pid" ]; then
    lock_pid="$(cat "${pid_file}/pid" 2>/dev/null || true)"
  elif [ -n "$pid_file" ] && [ -f "$pid_file" ] && [ -r "$pid_file" ]; then
    lock_pid="$(cat "$pid_file" 2>/dev/null || true)"
  fi
  case "$lock_pid" in
  '' | *[!0-9]*)
    lock_pid=""
    ;;
  esac

  printf '%s\n' "$lock_pid"
}

function dockistrate_test_state_sandbox_write_lock_pid() {
  local pid_file="${1:-}"
  local lock_pid=""

  [ -n "$pid_file" ] || return 1
  # Bash 3 has no BASHPID; ask a Bash child for this shell's actual process ID.
  "${BASH:-bash}" -c 'printf "%s\n" "$PPID"' >"$pid_file" || return 1
  lock_pid="$(dockistrate_test_state_sandbox_read_lock_pid "$pid_file")"
  [ -n "$lock_pid" ] || return 1
}

function dockistrate_test_state_sandbox_reclaim_stale_lock() {
  local lock_dir="${1:-}" stale_pid="${2:-}" current_pid=""

  [ -n "$lock_dir" ] || return 1
  current_pid="$(dockistrate_test_state_sandbox_read_lock_pid "$lock_dir")"
  if [ "$current_pid" != "$stale_pid" ]; then
    return 0
  fi
  if ! dockistrate_test_state_sandbox_lock_pid_is_reclaimable "$current_pid"; then
    return 0
  fi
  dockistrate_test_remove_dir_tree "$lock_dir"
}

function dockistrate_test_state_sandbox_lock_pid_is_reclaimable() {
  local lock_pid="${1:-}" probe_bin="" probe_status=0 kill_error=""

  case "$lock_pid" in
  '' | *[!0-9]*)
    return 0
    ;;
  esac
  if kill -0 "$lock_pid" 2>/dev/null; then
    return 1
  fi
  for probe_bin in python3 python; do
    if ! command -v "$probe_bin" >/dev/null 2>&1; then
      continue
    fi
    if "$probe_bin" - "$lock_pid" <<'PY'
import errno
import os
import sys

try:
    os.kill(int(sys.argv[1]), 0)
except OSError as exc:
    if exc.errno == errno.ESRCH:
        sys.exit(1)
    sys.exit(0)
else:
    sys.exit(0)
PY
    then
      return 1
    else
      probe_status=$?
    fi
    if [ "$probe_status" -eq 1 ]; then
      return 0
    fi
  done
  if command -v perl >/dev/null 2>&1; then
    if perl -e 'kill 0, $ARGV[0]; if ($!{ESRCH}) { exit 1 } exit 0' "$lock_pid"; then
      return 1
    else
      probe_status=$?
    fi
    if [ "$probe_status" -eq 1 ]; then
      return 0
    fi
  fi
  kill_error="$(kill -0 "$lock_pid" 2>&1 >/dev/null || true)"
  case "$kill_error" in
  *"No such process"* | *"no such process"*)
    return 0
    ;;
  esac
  return 1
}

function dockistrate_test_state_sandbox_lock_matches_pid() {
  local lock_dir="${1:-}" expected_pid="${2:-}" current_pid=""

  [ -n "$lock_dir" ] && [ -n "$expected_pid" ] || return 1
  [ -L "$lock_dir" ] || return 1
  current_pid="$(dockistrate_test_state_sandbox_read_lock_pid "$lock_dir")"
  [ "$current_pid" = "$expected_pid" ]
}

function dockistrate_test_state_sandbox_acquire_lock() {
  local lock_dir="${1:-}" attempt=1 max_attempts="${DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_RETRIES:-60}"
  local lock_pid="" pid_tmp="" nested_lock=""

  [ -n "$lock_dir" ] || return 1
  while :; do
    if [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
      lock_pid="$(dockistrate_test_state_sandbox_read_lock_pid "$lock_dir")"
    else
      pid_tmp="$(mktemp "${lock_dir}.pid.XXXXXX")" || return 1
      if ! dockistrate_test_state_sandbox_write_lock_pid "$pid_tmp"; then
        rm -f "$pid_tmp" 2>/dev/null || true
        return 1
      fi
      lock_pid="$(dockistrate_test_state_sandbox_read_lock_pid "$pid_tmp")"
      if [ -z "$lock_pid" ]; then
        rm -f "$pid_tmp" 2>/dev/null || true
        return 1
      fi
      if ln -s "$lock_pid" "$lock_dir" 2>/dev/null; then
        if dockistrate_test_state_sandbox_lock_matches_pid "$lock_dir" "$lock_pid"; then
          rm -f "$pid_tmp" 2>/dev/null || true
          return 0
        fi
        if [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ]; then
          nested_lock="${lock_dir}/${lock_pid}"
          if [ -L "$nested_lock" ]; then
            rm -f "$nested_lock" 2>/dev/null || {
              rm -f "$pid_tmp" 2>/dev/null || true
              return 1
            }
          fi
        fi
      fi
      rm -f "$pid_tmp" 2>/dev/null || true
      lock_pid="$(dockistrate_test_state_sandbox_read_lock_pid "$lock_dir")"
    fi

    if dockistrate_test_state_sandbox_lock_pid_is_reclaimable "$lock_pid"; then
      if ! dockistrate_test_state_sandbox_reclaim_stale_lock "$lock_dir" "$lock_pid"; then
        return 1
      fi
      continue
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      echo "[tests] Error: timed out waiting for test state sandbox lock: ${lock_dir}" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
}

function dockistrate_test_state_sandbox() {
  local root="${1:-}" snapshot_dir="" lock_dir=""

  if [ -z "$root" ]; then
    echo "[tests] Error: dockistrate_test_state_sandbox requires a repo root." >&2
    return 1
  fi
  if [ ! -d "$root" ]; then
    echo "[tests] Error: test state sandbox root does not exist: ${root}" >&2
    return 1
  fi

  root="$(cd "$root" && pwd)"
  if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_ACTIVE:-false}" = "true" ]; then
    return 0
  fi
  if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER:-false}" = "true" ]; then
    return 0
  fi

  mkdir -p "${root}/tmp" || return 1
  lock_dir="${root}/tmp/tests-state-sandbox.lock"
  dockistrate_test_state_sandbox_acquire_lock "$lock_dir" || return 1
  DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_DIR="$lock_dir"
  DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_HELD="true"

  snapshot_dir="${root}/tmp/tests-state-snapshot.$$"
  DOCKISTRATE_TEST_STATE_SANDBOX_ROOT="$root"
  DOCKISTRATE_TEST_STATE_SANDBOX_SNAPSHOT_DIR="$snapshot_dir"
  DOCKISTRATE_TEST_STATE_SANDBOX_STATE_PRESENT="false"
  if ! dockistrate_test_remove_dir_tree "$snapshot_dir"; then
    dockistrate_test_state_sandbox_restore
    return 1
  fi
  if ! mkdir -p "$snapshot_dir"; then
    dockistrate_test_state_sandbox_restore
    return 1
  fi

  if [ -e "${root}/state" ]; then
    if ! mv "${root}/state" "${snapshot_dir}/state"; then
      dockistrate_test_remove_dir_tree "$snapshot_dir" || true
      dockistrate_test_state_sandbox_restore
      return 1
    fi
    DOCKISTRATE_TEST_STATE_SANDBOX_STATE_PRESENT="true"
  fi

  DOCKISTRATE_TEST_STATE_SANDBOX_ACTIVE="true"
  if ! mkdir -p "${root}/state"; then
    dockistrate_test_state_sandbox_restore
    return 1
  fi
}

function dockistrate_test_state_sandbox_restore() {
  local root="${DOCKISTRATE_TEST_STATE_SANDBOX_ROOT:-}"
  local snapshot_dir="${DOCKISTRATE_TEST_STATE_SANDBOX_SNAPSHOT_DIR:-}"
  local state_present="${DOCKISTRATE_TEST_STATE_SANDBOX_STATE_PRESENT:-false}"
  local lock_dir="${DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_DIR:-}"
  local restore_status=0

  if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_ACTIVE:-false}" != "true" ]; then
    if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_HELD:-false}" = "true" ] && [ -n "$lock_dir" ]; then
      if ! dockistrate_test_remove_dir_tree "$lock_dir"; then
        restore_status=1
      fi
    fi
    DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_HELD="false"
    DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_DIR=""
    DOCKISTRATE_TEST_STATE_SANDBOX_ACTIVE="false"
    DOCKISTRATE_TEST_STATE_SANDBOX_ROOT=""
    DOCKISTRATE_TEST_STATE_SANDBOX_SNAPSHOT_DIR=""
    DOCKISTRATE_TEST_STATE_SANDBOX_STATE_PRESENT="false"
    return "$restore_status"
  fi

  if [ -n "$root" ]; then
    if ! dockistrate_test_remove_dir_tree "${root}/state"; then
      restore_status=1
    fi
  fi
  if [ "$restore_status" -eq 0 ] && [ "$state_present" = "true" ] && [ -n "$snapshot_dir" ] && [ -e "${snapshot_dir}/state" ]; then
    if ! mv "${snapshot_dir}/state" "${root}/state"; then
      echo "[tests] Error: failed to restore ${root}/state from ${snapshot_dir}/state" >&2
      echo "[tests] Error: original state retained for recovery at ${snapshot_dir}/state" >&2
      restore_status=1
    fi
  fi
  if [ "$restore_status" -eq 0 ] && [ -n "$snapshot_dir" ]; then
    if ! dockistrate_test_remove_dir_tree "$snapshot_dir"; then
      restore_status=1
    fi
  fi
  if [ "${DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_HELD:-false}" = "true" ] && [ -n "$lock_dir" ]; then
    if ! dockistrate_test_remove_dir_tree "$lock_dir"; then
      restore_status=1
    fi
  fi

  DOCKISTRATE_TEST_STATE_SANDBOX_ACTIVE="false"
  DOCKISTRATE_TEST_STATE_SANDBOX_ROOT=""
  DOCKISTRATE_TEST_STATE_SANDBOX_SNAPSHOT_DIR=""
  DOCKISTRATE_TEST_STATE_SANDBOX_STATE_PRESENT="false"
  DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_DIR=""
  DOCKISTRATE_TEST_STATE_SANDBOX_LOCK_HELD="false"
  return "$restore_status"
}
