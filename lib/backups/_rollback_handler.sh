# shellcheck shell=bash

function _rollback_clear_target_for_restore() {
  local target="${1:-}" clear_failed="false" clear_entry="" clear_list_file="" parent_dir=""
  [ -e "$target" ] || return 0
  if ! _safe_delete_validate_target "$target" "${STATE_DIR:-$BASE_DIR}" >/dev/null 2>&1; then
    return 0
  fi

  if [ -d "$target" ]; then
    if ! clear_list_file="$(mktemp "${TMP_DIR}/rollback_clear_XXXXXX" 2>/dev/null)"; then
      return 1
    fi
    if ! find "$target" -mindepth 1 -maxdepth 1 -print0 >"$clear_list_file" 2>/dev/null; then
      safe_rm_f "$clear_list_file" "${TMP_DIR:-/tmp}" || true
      return 1
    fi
    while IFS= read -r -d '' clear_entry; do
      if ! safe_rm_rf "$clear_entry" "$target"; then
        clear_failed="true"
      fi
    done <"$clear_list_file"
    safe_rm_f "$clear_list_file" "${TMP_DIR:-/tmp}" || true
    [ "$clear_failed" != "true" ]
    return
  fi

  parent_dir="$(dirname "$target")"
  safe_rm_f "$target" "$parent_dir"
}

function _rollback_clear_targets_for_restore() {
  local rollback_target=""
  for rollback_target in "${ROLLBACK_FILES[@]-}"; do
    [ -n "$rollback_target" ] || continue
    if ! _rollback_clear_target_for_restore "$rollback_target"; then
      echo "[Warn] Failed to fully clear ${rollback_target} before rollback replay." >&2
    fi
  done
}

function _rollback_handler_common() {
  local rollback_desc="${ROLLBACK_DESC:-transaction}"
  capture_docker_logs "$rollback_desc" "$NGINX_CONTAINER_NAME" || {
    echo "[Warn] Failed to capture Docker logs during rollback; continuing rollback." >&2
  }
  if [ "${ROLLBACK_DESC:-}" = "restore_backup" ] && [ -n "${ROLLBACK_RESTORE_CLEAR_DIRS:-}" ]; then
    local clear_dir clear_target clear_failed
    for clear_dir in $ROLLBACK_RESTORE_CLEAR_DIRS; do
      [ -d "$clear_dir" ] || continue
      clear_failed="false"
      while IFS= read -r -d '' clear_target; do
        if ! safe_rm_rf "$clear_target" "$clear_dir"; then
          clear_failed="true"
        fi
      done < <(find "$clear_dir" -mindepth 1 -print0 2>/dev/null)
      if [ "$clear_failed" = "true" ]; then
        echo "[Warn] Failed to fully clear ${clear_dir} before rollback replay." >&2
      fi
    done
  else
    _rollback_clear_targets_for_restore
  fi
  restore_backup_archive "$PRE_CHANGE_BACKUP"
  for f in "${ROLLBACK_NEW_FILES[@]-}"; do
    [ -n "$f" ] || continue
    safe_rm_rf "$f" "${STATE_DIR:-$CONFIG_DIR}" || true
  done
  run_rollback_pre_hooks
  if declare -F _nginx_clear_runtime_rollback_state >/dev/null 2>&1; then
    _nginx_clear_runtime_rollback_state || true
  fi
  if declare -F load_config >/dev/null 2>&1; then
    load_config >/dev/null 2>&1 || true
  fi
  echo "[Error] ${rollback_desc} failed. Rolled back." >&2
  if declare -F log_msg >/dev/null 2>&1; then
    log_msg "Rollback performed for ${rollback_desc}"
  fi
  _transaction_clear_installed_traps
  unset ROLLBACK_DESC ROLLBACK_FILES ROLLBACK_NEW_FILES PRE_CHANGE_BACKUP
  unset ROLLBACK_RESTORE_CLEAR_DIRS ROLLBACK_PRE_HOOK
  unset TRANSACTION_DEPTH TRANSACTION_OWNER_PID TRANSACTION_MODE
  release_transaction_lock || true
}

function _rollback_handler() {
  if ! transaction_is_active; then
    return 1
  fi
  _rollback_handler_common
  exit 1
}

function _rollback_handler_return() {
  if ! transaction_is_active; then
    return 1
  fi
  _rollback_handler_common
  return 1
}
