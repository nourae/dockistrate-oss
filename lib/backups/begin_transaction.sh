# shellcheck shell=bash

function _begin_transaction_cleanup_failed_start() {
  if declare -F _nginx_clear_runtime_rollback_state >/dev/null 2>&1; then
    _nginx_clear_runtime_rollback_state || true
  fi
  release_transaction_lock || true
  unset CONFIG_RUNTIME_PREP_LOCK_HELD CONFIG_RUNTIME_PREP_LOCK_OWNER_PID
  unset PRE_CHANGE_BACKUP ROLLBACK_DESC ROLLBACK_FILES ROLLBACK_NEW_FILES
  unset ROLLBACK_RESTORE_CLEAR_DIRS ROLLBACK_PRE_HOOK
  unset TRANSACTION_DEPTH TRANSACTION_OWNER_PID TRANSACTION_LOCK_HELD TRANSACTION_MODE
}

function _begin_transaction_common() {
  local mode="${1:-exit}"
  case "$mode" in
  exit | return) ;;
  *)
    echo "[Error] Invalid transaction mode: ${mode}" >&2
    return 1
    ;;
  esac

  local depth="${TRANSACTION_DEPTH:-0}"
  if transaction_is_active; then
    TRANSACTION_DEPTH=$((depth + 1))
    return 0
  fi

  local promoted_runtime_prep_lock="false"
  if declare -F _config_runtime_prep_lock_is_active >/dev/null 2>&1 &&
    _config_runtime_prep_lock_is_active; then
    promoted_runtime_prep_lock="true"
  elif ! acquire_transaction_lock; then
    return 1
  fi

  if declare -F domain_config_runtime_recover >/dev/null 2>&1 &&
    { [ "${DOMAIN_CONFIG_ACTIVE:-false}" = true ] || domain_config_runtime_recovery_pending; }; then
    if ! domain_config_runtime_recover; then
      release_transaction_lock || true
      return 1
    fi
  fi

  local desc="${2:-txn}"
  shift 2
  local raw_target="" normalized_target="" existing_target="" skip_target=false
  local state_root_physical=""
  if ! state_root_physical="$(_realpath_portable "${STATE_DIR:-$BASE_DIR}" 2>/dev/null && printf '.')"; then
    echo "[Error] Unable to resolve transaction state root." >&2
    _begin_transaction_cleanup_failed_start
    return 1
  fi
  state_root_physical="${state_root_physical%.}"
  TRANSACTION_DEPTH=1
  TRANSACTION_OWNER_PID="$$"
  TRANSACTION_MODE="$mode"
  if [ "$promoted_runtime_prep_lock" = "true" ]; then
    unset CONFIG_RUNTIME_PREP_LOCK_HELD CONFIG_RUNTIME_PREP_LOCK_OWNER_PID
  fi
  ROLLBACK_DESC="$desc"
  ROLLBACK_FILES=()
  for raw_target in "$@"; do
    [ -n "$raw_target" ] || continue
    if ! normalized_target="$(_normalize_transaction_backup_target "$raw_target" && printf '.')"; then
      echo "[Error] Invalid rollback target for transaction '${desc}': ${raw_target}" >&2
      _begin_transaction_cleanup_failed_start
      return 1
    fi
    normalized_target="${normalized_target%.}"
    if [ "$normalized_target" = "$state_root_physical" ]; then
      echo "[Error] Refusing transaction target at the state root itself: ${raw_target}" >&2
      _begin_transaction_cleanup_failed_start
      return 1
    fi

    skip_target=false
    if [ "${#ROLLBACK_FILES[@]}" -gt 0 ]; then
      for existing_target in "${ROLLBACK_FILES[@]}"; do
        case "$normalized_target" in
        "$existing_target" | "$existing_target"/*)
          skip_target=true
          break
          ;;
        esac
      done
    fi
    [ "$skip_target" = true ] && continue
    # A parent supplied after a child must replace that child too; duplicate
    # archive members would otherwise make the snapshot ambiguous to replay.
    local kept_targets=()
    for existing_target in "${ROLLBACK_FILES[@]-}"; do
      [ -n "$existing_target" ] || continue
      case "$existing_target" in
      "$normalized_target"/*) ;;
      *) kept_targets+=("$existing_target") ;;
      esac
    done
    ROLLBACK_FILES=()
    for existing_target in "${kept_targets[@]-}"; do
      [ -n "$existing_target" ] && ROLLBACK_FILES+=("$existing_target")
    done
    ROLLBACK_FILES+=("$normalized_target")
  done
  ROLLBACK_NEW_FILES=()
  if [ "${#ROLLBACK_FILES[@]}" -gt 0 ]; then
    for f in "${ROLLBACK_FILES[@]}"; do
      [[ -e "$f" ]] || ROLLBACK_NEW_FILES+=("$f")
    done
  fi
  local cur_rollback_state_signature="" last_rollback_state_signature="" last_post_backup=""
  local rollback_targets_signature_file="${BACKUP_DIR}/last_rollback_targets.sha256"
  local rollback_state_signature_file="${BACKUP_DIR}/last_rollback_state.sha256"
  local cur_rollback_targets_signature="" last_rollback_targets_signature=""
  local reuse_candidate="false"
  [ -f "$LAST_POST_BACKUP_FILE" ] && last_post_backup="$(cat "$LAST_POST_BACKUP_FILE")"
  [ -f "$rollback_targets_signature_file" ] && last_rollback_targets_signature="$(cat "$rollback_targets_signature_file")"
  [ -f "$rollback_state_signature_file" ] && last_rollback_state_signature="$(cat "$rollback_state_signature_file")"
  if [ -n "$last_rollback_targets_signature" ] &&
    [ -n "$last_rollback_state_signature" ] &&
    is_transaction_backup_archive "$last_post_backup"; then
    reuse_candidate="true"
  fi

  if ! cur_rollback_targets_signature="$(_rollback_targets_signature "${ROLLBACK_FILES[@]}")"; then
    echo "[Error] Failed to compute rollback target signature for transaction '${desc}'." >&2
    _begin_transaction_cleanup_failed_start
    return 1
  fi

  if [ "$reuse_candidate" = "true" ] &&
    [ "$cur_rollback_targets_signature" = "$last_rollback_targets_signature" ]; then
    if ! cur_rollback_state_signature="$(_rollback_targets_state_signature "${ROLLBACK_FILES[@]}")"; then
      echo "[Error] Failed to compute rollback target state signature for transaction '${desc}'." >&2
      _begin_transaction_cleanup_failed_start
      return 1
    fi
    if [ "$cur_rollback_state_signature" = "$last_rollback_state_signature" ]; then
      if ! _validate_transaction_backup_targets "${STATE_DIR:-$BASE_DIR}" "${ROLLBACK_FILES[@]-}"; then
        _begin_transaction_cleanup_failed_start
        return 1
      fi
      # A stale or damaged cached snapshot must not become the only recovery
      # copy. Fall through to a fresh backup when its checksum no longer agrees.
      if _verify_backup_archive_checksum_if_present "$last_post_backup"; then
        PRE_CHANGE_BACKUP="$last_post_backup"
      fi
    fi
  fi

  if [ -z "${PRE_CHANGE_BACKUP:-}" ]; then
    if ! PRE_CHANGE_BACKUP="$(backup_files_only "pre_${desc}" "${ROLLBACK_FILES[@]}")"; then
      echo "[Error] Failed to create pre-change backup for transaction '${desc}'." >&2
      _begin_transaction_cleanup_failed_start
      return 1
    fi
  fi
  # CONFIG_DIR replay can change a mounted snapshot's owner even when the
  # command fails before rendering or only reloads its existing proxy.
  if declare -F _nginx_prepare_projection_transaction_rollback >/dev/null 2>&1; then
    if ! _nginx_prepare_projection_transaction_rollback; then
      _begin_transaction_cleanup_failed_start
      return 1
    fi
  fi
  if [ "$mode" = "exit" ]; then
    trap '_rollback_handler' ERR EXIT
  fi
  if [ "${DOMAIN_CONFIG_ACTIVE:-false}" = true ] &&
    declare -F domain_config_runtime_prepare >/dev/null 2>&1; then
    if ! domain_config_runtime_prepare; then
      _begin_transaction_cleanup_failed_start
      return 1
    fi
  fi
}

# Begin a transaction backed by a pre-change backup
function begin_transaction() {
  if [ "${1:-}" = --permissions ]; then
    shift
    _permissions_transaction_begin "$@"
    return $?
  fi
  _begin_transaction_common exit "$@"
}

function begin_transaction_return() {
  _begin_transaction_common return "$@"
}
