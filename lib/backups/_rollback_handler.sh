# shellcheck shell=bash

function _rollback_handler_common() {
  local rollback_desc="${ROLLBACK_DESC:-transaction}" rollback_archive="${PRE_CHANGE_BACKUP:-}"
  local rollback_failed=false configuration_loaded=true
  # The durable marker is the commit boundary, including during signal delivery
  # before end_transaction_success has cleared its in-memory transaction state.
  if [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] &&
    [ "$(_domain_runtime_get "$DOMAIN_CONFIG_RUNTIME_JOURNAL/transaction.csv" phase)" = committed ]; then
    _transaction_clear_installed_traps
    domain_config_runtime_cleanup || true
    if declare -F _nginx_clear_runtime_rollback_state >/dev/null 2>&1; then _nginx_clear_runtime_rollback_state; fi
    unset ROLLBACK_DESC ROLLBACK_FILES ROLLBACK_NEW_FILES PRE_CHANGE_BACKUP
    unset ROLLBACK_RESTORE_CLEAR_DIRS ROLLBACK_PRE_HOOK TRANSACTION_DEPTH TRANSACTION_OWNER_PID TRANSACTION_MODE
    release_transaction_lock || true
    return 0
  fi
  # A rollback error must not recursively enter this handler. Return-mode
  # transactions leave unrelated caller traps untouched.
  _transaction_clear_installed_traps
  capture_docker_logs "$rollback_desc" "$NGINX_CONTAINER_NAME" || {
    echo "[Warn] Failed to capture Docker logs during rollback; continuing rollback." >&2
  }
  if restore_backup_archive "$rollback_archive" "${ROLLBACK_FILES[@]-}"; then
    if declare -F load_config >/dev/null 2>&1; then
      local restore_settings=load_config
      if [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] &&
        declare -F _domain_runtime_load_restored_settings >/dev/null 2>&1; then
        restore_settings=_domain_runtime_load_restored_settings
      fi
      if ! "$restore_settings" >/dev/null 2>&1; then
        echo "[Error] Failed to reload configuration after rollback." >&2
        rollback_failed=true
        configuration_loaded=false
      fi
    fi
    # Runtime recovery must use the restored settings, not values assigned by
    # the failed command (for example invalid Nginx Docker options).
    if [ "$configuration_loaded" = true ] && ! run_rollback_pre_hooks; then
      rollback_failed=true
    fi
  else
    # Runtime hooks must not apply stale configuration after file recovery fails.
    rollback_failed=true
  fi
  if declare -F _nginx_clear_runtime_rollback_state >/dev/null 2>&1; then
    _nginx_clear_runtime_rollback_state || rollback_failed=true
  fi
  if ! release_transaction_lock; then
    echo "[Error] Failed to release the transaction lock after rollback." >&2
    rollback_failed=true
  fi
  if [ "$rollback_failed" = false ]; then
    echo "[Error] ${rollback_desc} failed. Rolled back." >&2
    if declare -F log_msg >/dev/null 2>&1; then
      log_msg "Rollback performed for ${rollback_desc}" || true
    fi
  else
    echo "[Error] ${rollback_desc} failed. Rollback failed or is incomplete; retain backup: ${rollback_archive}" >&2
    if declare -F log_msg >/dev/null 2>&1; then
      log_msg "Rollback incomplete for ${rollback_desc}; backup: ${rollback_archive}" || true
    fi
  fi
  unset ROLLBACK_DESC ROLLBACK_FILES ROLLBACK_NEW_FILES PRE_CHANGE_BACKUP
  unset ROLLBACK_RESTORE_CLEAR_DIRS ROLLBACK_PRE_HOOK
  unset TRANSACTION_DEPTH TRANSACTION_OWNER_PID TRANSACTION_MODE
  [ "$rollback_failed" = false ]
}

function _rollback_handler() {
  if ! transaction_is_active; then
    return 1
  fi
  _rollback_handler_common || true
  exit 1
}

function _rollback_handler_return() {
  if ! transaction_is_active; then
    return 1
  fi
  _rollback_handler_common || true
  return 1
}
