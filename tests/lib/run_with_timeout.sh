#!/usr/bin/env bash
set -Eeuo pipefail

function print_timeout_dependency_error() {
  echo "[tests] Error: GNU timeout is required for test timeouts (install 'timeout', 'gtimeout' or 'gnutimeout'; on macOS: brew install coreutils)." >&2
}

function resolve_timeout_backend() {
  local candidate version_output
  for candidate in timeout gtimeout gnutimeout; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi

    version_output="$("$candidate" --version 2>/dev/null || true)"
    case "$version_output" in
    *"GNU coreutils"*)
      printf '%s\n' "$candidate"
      return 0
      ;;
    esac
  done

  return 1
}

if [ "${1:-}" = "--probe" ]; then
  if resolve_timeout_backend >/dev/null 2>&1; then
    exit 0
  fi

  print_timeout_dependency_error
  exit 2
fi

timeout_seconds="${1:-}"
grace_seconds="${2:-}"
label="${3:-}"

if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [ "$timeout_seconds" -le 0 ]; then
  echo "[tests] Error: timeout_seconds must be a positive integer." >&2
  exit 2
fi
if ! [[ "$grace_seconds" =~ ^[0-9]+$ ]] || [ "$grace_seconds" -lt 0 ]; then
  echo "[tests] Error: grace_seconds must be a non-negative integer." >&2
  exit 2
fi

shift 3 || true
if [ "${1:-}" != "--" ]; then
  echo "[tests] Usage: run_with_timeout.sh <timeout_seconds> <grace_seconds> <label> -- <command...>" >&2
  exit 2
fi
shift || true
if [ "$#" -eq 0 ]; then
  echo "[tests] Error: run_with_timeout.sh requires a command." >&2
  exit 2
fi

if ! timeout_backend="$(resolve_timeout_backend)"; then
  print_timeout_dependency_error
  exit 2
fi

status_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate.run_with_timeout.status.XXXXXX")"
timeout_pid=""
cancel_status=0

function cancel_timeout() {
  [ "$cancel_status" -eq 0 ] || return 0
  cancel_status="$1"
  if [ -n "$timeout_pid" ]; then
    kill -TERM "$timeout_pid" >/dev/null 2>&1 || true
  fi
}

function cleanup_timeout() {
  local exit_status=$?
  trap '' INT TERM
  if [ -n "$timeout_pid" ]; then
    kill -TERM "$timeout_pid" >/dev/null 2>&1 || true
    # Pending signals can leave several stale wait statuses. The timeout
    # process owns the bounded descendant cleanup; wait for its actual exit.
    while ! wait "$timeout_pid" 2>/dev/null; do
      kill -0 "$timeout_pid" 2>/dev/null || break
    done
  fi
  rm -f "${status_file:-}"
  return "$exit_status"
}
trap 'cancel_timeout 130' INT
trap 'cancel_timeout 143' TERM
trap cleanup_timeout EXIT

cleanup_wait_checks=20
cleanup_wait_seconds=$(((cleanup_wait_checks + 9) / 10))
post_timeout_cleanup_seconds=$((cleanup_wait_seconds * 2))
kill_after_seconds=$((grace_seconds + post_timeout_cleanup_seconds + 1))

timeout_wrapper='
set -Eeuo pipefail

grace_seconds="$1"
cleanup_wait_checks="$2"
status_file="$3"
shift 3

child_pid=""
timed_out=0
interrupted=0
children_cleaned=0
tracked_descendants=()

function process_group_exists() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  kill -0 -- "-${pid}" >/dev/null 2>&1
}

function pid_exists() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

function kill_process_group() {
  local signal="${1:-}"
  local pid="${2:-}"
  [ -n "$signal" ] || return 1
  [ -n "$pid" ] || return 0
  kill -"${signal}" -- "-${pid}" >/dev/null 2>&1 || true
}

function list_child_pids() {
  local parent_pid="${1:-}"
  local listed_pid="" listed_ppid=""
  [ -n "$parent_pid" ] || return 0

  while read -r listed_pid listed_ppid; do
    if [ "$listed_ppid" = "$parent_pid" ]; then
      printf "%s\n" "$listed_pid"
    fi
  done < <(ps -e -o pid= -o ppid=)
}

function collect_descendant_pids() {
  local parent_pid="${1:-}"
  local descendant_pid=""
  [ -n "$parent_pid" ] || return 0

  while IFS= read -r descendant_pid; do
    [ -n "$descendant_pid" ] || continue
    printf "%s\n" "$descendant_pid"
    collect_descendant_pids "$descendant_pid"
  done < <(list_child_pids "$parent_pid")
}

function snapshot_descendants() {
  local root_pid="${1:-}"
  local descendant_pid=""
  tracked_descendants=()
  [ -n "$root_pid" ] || return 0

  while IFS= read -r descendant_pid; do
    [ -n "$descendant_pid" ] || continue
    tracked_descendants+=("$descendant_pid")
  done < <(collect_descendant_pids "$root_pid" | sort -u)
}

function write_status() {
  local value="${1:-}"
  [ -n "$status_file" ] || return 0
  printf "%s\n" "$value" >"$status_file"
}

function wait_for_process_group_exit() {
  local pid="${1:-}"
  local checks="${2:-0}"
  [ -n "$pid" ] || return 0

  while [ "$checks" -gt 0 ]; do
    if ! process_group_exists "$pid"; then
      return 0
    fi
    sleep 0.1
    checks=$((checks - 1))
  done

  ! process_group_exists "$pid"
}

function wait_for_tracked_descendants_exit() {
  local checks="${1:-0}"
  local tracked_pid=""
  local idx=0
  local remaining=0

  if [ "${#tracked_descendants[@]}" -eq 0 ]; then
    return 0
  fi

  while [ "$checks" -gt 0 ]; do
    remaining=0
    for idx in "${!tracked_descendants[@]}"; do
      tracked_pid="${tracked_descendants[$idx]}"
      [ -n "$tracked_pid" ] || continue
      if pid_exists "$tracked_pid"; then
        remaining=1
        break
      fi
    done
    if [ "$remaining" -eq 0 ]; then
      return 0
    fi
    sleep 0.1
    checks=$((checks - 1))
  done

  remaining=0
  for idx in "${!tracked_descendants[@]}"; do
    tracked_pid="${tracked_descendants[$idx]}"
    [ -n "$tracked_pid" ] || continue
    if pid_exists "$tracked_pid"; then
      remaining=1
      break
    fi
  done

  [ "$remaining" -eq 0 ]
}

function cleanup_children() {
  [ -n "$child_pid" ] || return 0
  [ "$children_cleaned" -eq 0 ] || return 0
  children_cleaned=1
  trap "" INT TERM
  if process_group_exists "$child_pid"; then
    snapshot_descendants "$child_pid"
    kill_process_group TERM "$child_pid"
    if [ "$grace_seconds" -gt 0 ]; then
      sleep "$grace_seconds"
    fi
    if process_group_exists "$child_pid"; then
      kill_process_group KILL "$child_pid"
    fi
  fi
  wait "$child_pid" 2>/dev/null || true
  wait_for_process_group_exit "$child_pid" "$cleanup_wait_checks" || true
  wait_for_tracked_descendants_exit "$cleanup_wait_checks" || true
}

function cleanup_on_exit() {
  local exit_status=$?
  cleanup_children
  return "$exit_status"
}

function handle_timeout() {
  timed_out=1
  cleanup_children
}

function handle_interrupt() {
  interrupted=1
  cleanup_children
}

trap "handle_timeout" TERM
trap "handle_interrupt" INT
trap "cleanup_on_exit" EXIT

set -m
"$@" &
child_pid=$!
set +m

# A signal can arrive between starting the child and assigning its PID.
if [ "$timed_out" -eq 1 ] || [ "$interrupted" -eq 1 ]; then
  cleanup_children
fi

set +e
wait "$child_pid"
rc=$?
set -e

if [ "$interrupted" -eq 1 ]; then
  write_status "exit:130"
  exit 130
fi

if [ "$timed_out" -eq 1 ]; then
  write_status "timeout"
  exit 124
fi

if process_group_exists "$child_pid"; then
  if ! wait_for_process_group_exit "$child_pid" "$cleanup_wait_checks"; then
    cleanup_children
  fi
fi

write_status "exit:${rc}"
exit "$rc"
'

rc=0
set +e
# Waiting for a background process lets Bash run cancellation traps immediately.
# Give it its own group so INT is not inherited as ignored by the wrapper.
set -m
"$timeout_backend" -k "$kill_after_seconds" "$timeout_seconds" bash -c "$timeout_wrapper" bash "$grace_seconds" "$cleanup_wait_checks" "$status_file" "$@" &
timeout_pid=$!
set +m
if [ "$cancel_status" -ne 0 ]; then
  exit "$cancel_status"
fi
wait "$timeout_pid"
rc=$?
set -e
if [ "$cancel_status" -ne 0 ]; then
  exit "$cancel_status"
fi
timeout_pid=""

status_value=""
if [ -s "$status_file" ]; then
  status_value="$(cat "$status_file")"
fi

case "$status_value" in
timeout)
  echo "[tests] Timed out after ${timeout_seconds}s: ${label}" >&2
  exit 124
  ;;
exit:*)
  status_rc="${status_value#exit:}"
  if [[ "$status_rc" =~ ^[0-9]+$ ]]; then
    exit "$status_rc"
  fi
  ;;
esac

exit "$rc"
