# shellcheck shell=bash

function _transaction_lock_now_epoch() {
  date '+%s'
}

function _transaction_lock_mtime_epoch() {
  local path="${1:-}" mtime=""
  [ -n "$path" ] || return 1
  mtime="$(stat -c '%Y' "$path" 2>/dev/null || true)"
  if [ -n "$mtime" ]; then
    printf '%s' "$mtime"
    return 0
  fi
  mtime="$(stat -f '%m' "$path" 2>/dev/null || true)"
  if [ -n "$mtime" ]; then
    printf '%s' "$mtime"
    return 0
  fi
  return 1
}

function _transaction_lock_age_seconds() {
  local lock_dir="${1:-}" mtime now
  [ -n "$lock_dir" ] || return 1
  if ! mtime="$(_transaction_lock_mtime_epoch "$lock_dir" 2>/dev/null)"; then
    return 1
  fi
  if ! now="$(_transaction_lock_now_epoch 2>/dev/null)"; then
    return 1
  fi
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  if [ "$now" -lt "$mtime" ]; then
    printf '0'
    return 0
  fi
  printf '%s' "$((now - mtime))"
}

function _transaction_lock_dir() {
  local tmp_root="${TMP_DIR:-${STATE_DIR:-/tmp}}"
  printf '%s' "${tmp_root}/.dockistrate_transaction.lock"
}

function _transaction_lock_owner_file() {
  local lock_dir="${1:-}"
  if [ -z "$lock_dir" ]; then
    lock_dir="$(_transaction_lock_dir)"
  fi
  printf '%s' "${lock_dir}/owner"
}

function _transaction_lock_owner_pid() {
  local owner_file="${1:-}"
  [ -f "$owner_file" ] || return 1
  awk -F'=' '$1=="pid"{print $2; exit}' "$owner_file"
}

function _transaction_lock_owner_cmd() {
  local owner_file="${1:-}"
  [ -f "$owner_file" ] || return 1
  awk -F'=' '$1=="cmd"{print $2; exit}' "$owner_file"
}

function _transaction_lock_pid_running() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  # If kill is denied (for example EPERM across users), ps still indicates liveness.
  ps -p "$pid" >/dev/null 2>&1
}

function _transaction_lock_owner_pid_with_retry() {
  local owner_file="${1:-}" owner_pid="" attempt=1 max_attempts=5
  [ -n "$owner_file" ] || return 1

  while [ "$attempt" -le "$max_attempts" ]; do
    owner_pid="$(_transaction_lock_owner_pid "$owner_file" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
      printf '%s' "$owner_pid"
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep 0.1 2>/dev/null || sleep 1
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

function _transaction_lock_write_owner() {
  local lock_dir="${1:-}"
  local owner_file
  owner_file="$(_transaction_lock_owner_file "$lock_dir")"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$owner_file" "transaction lock owner file" || return 1
  fi
  {
    printf 'pid=%s\n' "$$"
    printf 'ppid=%s\n' "$PPID"
    printf 'cmd=%s\n' "$0"
    printf 'started_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  } >"$owner_file"
}

function acquire_transaction_lock() {
  if transaction_is_active; then
    return 0
  fi
  unset TRANSACTION_LOCK_HELD

  local lock_dir owner_file owner_pid owner_cmd lock_age
  local ownerless_stale_ttl=300
  lock_dir="$(_transaction_lock_dir)"
  owner_file="$(_transaction_lock_owner_file "$lock_dir")"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$(dirname "$lock_dir")" "transaction lock parent directory" || return 1
    runtime_state_path_guard_if_declared "$lock_dir" "transaction lock directory" || return 1
    runtime_state_path_guard_if_declared "$owner_file" "transaction lock owner file" || return 1
  fi
  mkdir -p "$(dirname "$lock_dir")" || return 1

  if mkdir "$lock_dir" 2>/dev/null; then
    if ! _transaction_lock_write_owner "$lock_dir"; then
      rm -rf "$lock_dir" 2>/dev/null || true
      unset TRANSACTION_LOCK_HELD
      return 1
    fi
    TRANSACTION_LOCK_HELD="true"
    return 0
  fi

  owner_pid="$(_transaction_lock_owner_pid_with_retry "$owner_file" 2>/dev/null || true)"
  if [[ "$owner_pid" =~ ^[0-9]+$ ]] && _transaction_lock_pid_running "$owner_pid"; then
    owner_cmd="$(_transaction_lock_owner_cmd "$owner_file" 2>/dev/null || true)"
    if [ -n "$owner_cmd" ]; then
      echo "[Error] Another mutating operation is in progress (PID ${owner_pid}, cmd=${owner_cmd}). Retry after it completes." >&2
    else
      echo "[Error] Another mutating operation is in progress (PID ${owner_pid}). Retry after it completes." >&2
    fi
    return 1
  fi

  if ! [[ "$owner_pid" =~ ^[0-9]+$ ]]; then
    lock_age="$(_transaction_lock_age_seconds "$lock_dir" 2>/dev/null || true)"
    if ! [[ "$lock_age" =~ ^[0-9]+$ ]] || [ "$lock_age" -lt "$ownerless_stale_ttl" ]; then
      echo "[Error] Another mutating operation is in progress (lock owner metadata unavailable). Retry after it completes." >&2
      return 1
    fi
    echo "[Warn] Reclaiming stale transaction lock with missing owner metadata at ${lock_dir} (age ${lock_age}s)." >&2
  else
    echo "[Warn] Reclaiming stale transaction lock at ${lock_dir}." >&2
  fi

  rm -rf "$lock_dir" 2>/dev/null || true
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "[Error] Unable to acquire transaction lock at ${lock_dir}." >&2
    return 1
  fi

  if ! _transaction_lock_write_owner "$lock_dir"; then
    rm -rf "$lock_dir" 2>/dev/null || true
    unset TRANSACTION_LOCK_HELD
    return 1
  fi
  TRANSACTION_LOCK_HELD="true"
}

function release_transaction_lock() {
  if [ "${TRANSACTION_LOCK_HELD:-false}" != "true" ]; then
    return 0
  fi

  local lock_dir
  lock_dir="$(_transaction_lock_dir)"
  rm -rf "$lock_dir" 2>/dev/null || {
    echo "[Warn] Failed to release transaction lock at ${lock_dir}." >&2
    return 1
  }
  unset TRANSACTION_LOCK_HELD
}
