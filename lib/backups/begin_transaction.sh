# shellcheck shell=bash

function _begin_transaction_cleanup_failed_start() {
  release_transaction_lock || true
  unset PRE_CHANGE_BACKUP ROLLBACK_DESC ROLLBACK_FILES ROLLBACK_NEW_FILES
  unset ROLLBACK_RESTORE_CLEAR_DIRS ROLLBACK_PRE_HOOK
  unset TRANSACTION_DEPTH TRANSACTION_OWNER_PID TRANSACTION_LOCK_HELD TRANSACTION_MODE
}

function _begin_transaction_normalize_target() {
  local target="${1:-}" normalized=""
  [ -n "$target" ] || return 1

  normalized="$target"
  while [ "${normalized%/}" != "$normalized" ] && [ "$normalized" != "/" ]; do
    normalized="${normalized%/}"
  done

  if [ "${normalized#/}" = "$normalized" ]; then
    normalized="$PWD/${normalized#./}"
  fi

  printf '%s\n' "$normalized"
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

  if ! acquire_transaction_lock; then
    return 1
  fi

  local desc="${2:-txn}"
  shift 2
  local raw_target="" normalized_target="" existing_target="" skip_target=false
  TRANSACTION_DEPTH=1
  TRANSACTION_OWNER_PID="$$"
  TRANSACTION_MODE="$mode"
  ROLLBACK_DESC="$desc"
  ROLLBACK_FILES=()
  for raw_target in "$@"; do
    [ -n "$raw_target" ] || continue
    if ! normalized_target="$(_begin_transaction_normalize_target "$raw_target")"; then
      echo "[Error] Invalid rollback target for transaction '${desc}': ${raw_target}" >&2
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
      PRE_CHANGE_BACKUP="$last_post_backup"
    fi
  fi

  if [ -z "${PRE_CHANGE_BACKUP:-}" ]; then
    if ! PRE_CHANGE_BACKUP="$(backup_files_only "pre_${desc}" "${ROLLBACK_FILES[@]}")"; then
      echo "[Error] Failed to create pre-change backup for transaction '${desc}'." >&2
      _begin_transaction_cleanup_failed_start
      return 1
    fi
  fi
  if [ "$mode" = "exit" ]; then
    trap '_rollback_handler' ERR EXIT
  fi
}

# Begin a transaction backed by a pre-change backup
function begin_transaction() {
  _begin_transaction_common exit "$@"
}

function begin_transaction_return() {
  _begin_transaction_common return "$@"
}
