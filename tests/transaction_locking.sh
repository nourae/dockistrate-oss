#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"

BASE_DIR="$ROOT_DIR"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
ORIG_RUNTIME_STATE_PATH_GUARD_IF_DECLARED_DEF="$(declare -f runtime_state_path_guard_if_declared)"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR"
touch "$CONFIG_DIR/state.txt"
lock_dir="${TMP_DIR}/.dockistrate_transaction.lock"

begin_transaction "lock_owner" "$CONFIG_DIR"

child_output=""
if child_output="$(
  ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/lib/config.sh"
    source "$ROOT_DIR/lib/utils.sh"
    source "$ROOT_DIR/lib/backups.sh"
    mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR"
    begin_transaction "lock_contender" "$CONFIG_DIR"
  ' 2>&1
)"; then
  child_status=0
else
  child_status=$?
fi

if [ "$child_status" -eq 0 ]; then
  echo "[Error] Expected concurrent lock contender to fail fast." >&2
  exit 1
fi
if ! grep -Fq "Another mutating operation is in progress" <<<"$child_output"; then
  echo "[Error] Expected lock contention error message." >&2
  exit 1
fi

end_transaction_success

# Dead-owner lock is reclaimed.
mkdir -p "$lock_dir"
cat >"${lock_dir}/owner" <<'EOF_OWNER'
pid=999999
ppid=1
cmd=/bin/false
started_at=1970-01-01T00:00:00+0000
EOF_OWNER

begin_transaction "stale_lock_recovery" "$CONFIG_DIR"
owner_pid="$(awk -F'=' '$1=="pid"{print $2; exit}' "${lock_dir}/owner" 2>/dev/null || true)"
if [ "$owner_pid" != "$$" ]; then
  echo "[Error] Expected stale lock owner to be replaced with current PID." >&2
  exit 1
fi
end_transaction_success

# Owner-file guard failure must not claim or leave a lock.
rm -rf "$lock_dir"
(
  eval "$(printf '%s\n' "$ORIG_RUNTIME_STATE_PATH_GUARD_IF_DECLARED_DEF" | sed '1s/runtime_state_path_guard_if_declared/original_runtime_state_path_guard_if_declared/')"
  function runtime_state_path_guard_if_declared() {
    if [ "${2:-}" = "transaction lock owner file" ]; then
      echo "[Error] Refusing to use transaction lock owner file for runtime guard test." >&2
      return 1
    fi
    original_runtime_state_path_guard_if_declared "$@"
  }

  set +e
  owner_guard_output="$(begin_transaction "owner_guard_failure" "$CONFIG_DIR" 2>&1)"
  owner_guard_status=$?
  set -e

  if [ "$owner_guard_status" -eq 0 ]; then
    echo "[Error] Expected transaction lock owner guard failure to fail begin_transaction." >&2
    exit 1
  fi
  if ! grep -Fq "transaction lock owner file" <<<"$owner_guard_output"; then
    echo "[Error] Expected owner-file guard failure output." >&2
    exit 1
  fi
  if [ -e "$lock_dir" ] || [ -L "$lock_dir" ]; then
    echo "[Error] Owner-file guard failure left the transaction lock on disk." >&2
    exit 1
  fi
  if [ -n "${TRANSACTION_LOCK_HELD:-}" ]; then
    echo "[Error] Owner-file guard failure marked the lock as held." >&2
    exit 1
  fi
)

# Simulate EPERM from kill -0; ps fallback must treat owner PID as running.
mkdir -p "$lock_dir"
cat >"${lock_dir}/owner" <<'EOF_OWNER'
pid=424242
ppid=1
cmd=/bin/false
started_at=1970-01-01T00:00:00+0000
EOF_OWNER

eperm_output=""
if eperm_output="$(
  ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/lib/config.sh"
    source "$ROOT_DIR/lib/utils.sh"
    source "$ROOT_DIR/lib/backups.sh"
    mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR"
    function kill() { return 1; }
    function ps() {
      if [ "${1:-}" = "-p" ] && [ "${2:-}" = "424242" ]; then
        return 0
      fi
      command ps "$@"
    }
    begin_transaction "eperm_lock_owner" "$CONFIG_DIR"
  ' 2>&1
)"; then
  eperm_status=0
else
  eperm_status=$?
fi

if [ "$eperm_status" -eq 0 ]; then
  echo "[Error] Expected EPERM-style owner check to fail fast." >&2
  exit 1
fi
if ! grep -Fq "Another mutating operation is in progress" <<<"$eperm_output"; then
  echo "[Error] Expected lock-owner contention error for EPERM-style check." >&2
  exit 1
fi
if ! grep -Fq "pid=424242" "${lock_dir}/owner"; then
  echo "[Error] EPERM-style contention should not reclaim lock ownership." >&2
  exit 1
fi

# Fresh ownerless lock should fail fast and avoid reclaim race.
rm -rf "$lock_dir"
mkdir -p "$lock_dir"
ownerless_output=""
if ownerless_output="$(begin_transaction "ownerless_fresh" "$CONFIG_DIR" 2>&1)"; then
  ownerless_status=0
else
  ownerless_status=$?
fi

if [ "$ownerless_status" -eq 0 ]; then
  echo "[Error] Expected ownerless fresh lock to fail fast." >&2
  exit 1
fi
if ! grep -Fq "owner metadata unavailable" <<<"$ownerless_output"; then
  echo "[Error] Expected ownerless lock metadata error message." >&2
  exit 1
fi
if [ -f "${lock_dir}/owner" ]; then
  echo "[Error] Fresh ownerless lock should not be reclaimed." >&2
  exit 1
fi

# Old ownerless lock should be reclaimed.
rm -rf "$lock_dir"
mkdir -p "$lock_dir"
touch -t 200001010000 "$lock_dir"
begin_transaction "ownerless_stale_reclaim" "$CONFIG_DIR"
owner_pid="$(awk -F'=' '$1=="pid"{print $2; exit}' "${lock_dir}/owner" 2>/dev/null || true)"
if [ "$owner_pid" != "$$" ]; then
  echo "[Error] Expected stale ownerless lock to be reclaimed." >&2
  exit 1
fi
end_transaction_success

# Pre-seeded transaction env must not bypass outermost lock/rollback setup.
rm -rf "$lock_dir"
TRANSACTION_DEPTH=9
TRANSACTION_LOCK_HELD=true
TRANSACTION_OWNER_PID=999999
ROLLBACK_DESC="env_leak"
begin_transaction "env_leak_guard" "$CONFIG_DIR"
if [ "${TRANSACTION_DEPTH:-0}" != "1" ]; then
  echo "[Error] begin_transaction should reset leaked depth for new outer transaction." >&2
  exit 1
fi
if [ "${TRANSACTION_OWNER_PID:-}" != "$$" ]; then
  echo "[Error] begin_transaction should set transaction owner to current process." >&2
  exit 1
fi
owner_pid="$(awk -F'=' '$1=="pid"{print $2; exit}' "${lock_dir}/owner" 2>/dev/null || true)"
if [ "$owner_pid" != "$$" ]; then
  echo "[Error] begin_transaction should reacquire the transaction lock after stale env leakage." >&2
  exit 1
fi
end_transaction_success

printf 'Transaction locking checks passed.\n'
