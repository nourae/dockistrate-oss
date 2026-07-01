# shellcheck shell=bash

function _end_transaction_success_fail() {
  local message="${1:-}"
  local failure_mode="${TRANSACTION_COMPLETION_FAILURE_MODE:-${TRANSACTION_MODE:-exit}}"
  [ -n "$message" ] && echo "$message" >&2

  if [ "$failure_mode" = "return" ] &&
    declare -F _rollback_handler_return >/dev/null 2>&1; then
    _rollback_handler_return
    return 1
  fi

  _rollback_handler
}

# Complete a transaction successfully and capture post-change backup
function end_transaction_success() {
  local depth="${TRANSACTION_DEPTH:-0}"
  if ! [[ "$depth" =~ ^[0-9]+$ ]] || [ "$depth" -le 0 ]; then
    _transaction_clear_installed_traps
    unset TRANSACTION_OWNER_PID TRANSACTION_MODE
    return 0
  fi

  if [ "$depth" -gt 1 ]; then
    TRANSACTION_DEPTH=$((depth - 1))
    return 0
  fi

  _transaction_clear_installed_traps
  if [ -z "${ROLLBACK_DESC:-}" ]; then
    unset TRANSACTION_DEPTH TRANSACTION_OWNER_PID TRANSACTION_MODE
    release_transaction_lock || true
    return 0
  fi

  local archive
  local rollback_targets_signature_file="${BACKUP_DIR}/last_rollback_targets.sha256"
  local rollback_state_signature_file="${BACKUP_DIR}/last_rollback_state.sha256"
  local rollback_targets_signature="" rollback_state_signature=""
  if ! archive="$(backup_files_only "post_${ROLLBACK_DESC}" "${ROLLBACK_FILES[@]}")"; then
    _end_transaction_success_fail "[Error] Failed to create post-change backup for transaction '${ROLLBACK_DESC}'."
    return 1
  fi
  if ! rollback_targets_signature="$(_rollback_targets_signature "${ROLLBACK_FILES[@]}")"; then
    _end_transaction_success_fail "[Error] Failed to compute rollback target signature for transaction '${ROLLBACK_DESC}'."
    return 1
  fi
  if ! rollback_state_signature="$(_rollback_targets_state_signature "${ROLLBACK_FILES[@]}")"; then
    _end_transaction_success_fail "[Error] Failed to compute rollback target state signature for transaction '${ROLLBACK_DESC}'."
    return 1
  fi
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$LAST_POST_BACKUP_FILE" "$rollback_targets_signature_file" "$rollback_state_signature_file" || {
      _end_transaction_success_fail "[Error] Failed to validate transaction metadata paths for transaction '${ROLLBACK_DESC}'."
      return 1
    }
  fi
  echo "$archive" >"$LAST_POST_BACKUP_FILE"
  printf '%s\n' "$rollback_targets_signature" >"$rollback_targets_signature_file"
  printf '%s\n' "$rollback_state_signature" >"$rollback_state_signature_file"
  unset PRE_CHANGE_BACKUP ROLLBACK_DESC ROLLBACK_FILES ROLLBACK_NEW_FILES ROLLBACK_RESTORE_CLEAR_DIRS
  unset ROLLBACK_PRE_HOOK
  unset TRANSACTION_DEPTH TRANSACTION_OWNER_PID TRANSACTION_MODE
  release_transaction_lock || true
}
