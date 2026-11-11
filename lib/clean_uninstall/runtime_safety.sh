# shellcheck shell=bash

function _cleanup_runtime_clear_staged_deletes() {
  rollback_pre_hook_remove "_cleanup_runtime_restore_staged_deletes_if_needed"
  unset CLEANUP_RUNTIME_DELETE_STATE_INITIALIZED
  unset CLEANUP_RUNTIME_DELETE_COUNT
  unset CLEANUP_RUNTIME_DELETE_NEXT_INDEX
  unset CLEANUP_RUNTIME_DELETE_RECOVERY_BACKUP
  unset CLEANUP_RUNTIME_DELETE_ORIGINALS
  unset CLEANUP_RUNTIME_DELETE_BACKUPS
  unset CLEANUP_RUNTIME_DELETE_WAS_RUNNING
  unset CLEANUP_RUNTIME_DELETE_IDS
  unset CLEANUP_RUNTIME_DELETE_DOMAINS
  unset CLEANUP_RUNTIME_DELETE_TOKENS
}

function _cleanup_runtime_init_staged_deletes() {
  if [ "${CLEANUP_RUNTIME_DELETE_STATE_INITIALIZED:-false}" = "true" ]; then
    return 0
  fi

  CLEANUP_RUNTIME_DELETE_STATE_INITIALIZED="true"
  CLEANUP_RUNTIME_DELETE_COUNT=0
  CLEANUP_RUNTIME_DELETE_NEXT_INDEX=0
  CLEANUP_RUNTIME_DELETE_RECOVERY_BACKUP="${PRE_CHANGE_BACKUP:-}"
  CLEANUP_RUNTIME_DELETE_ORIGINALS=()
  CLEANUP_RUNTIME_DELETE_BACKUPS=()
  CLEANUP_RUNTIME_DELETE_WAS_RUNNING=()
  CLEANUP_RUNTIME_DELETE_IDS=()
  CLEANUP_RUNTIME_DELETE_DOMAINS=()
  CLEANUP_RUNTIME_DELETE_TOKENS=()
}

function _cleanup_runtime_backup_name() {
  local cname="${1:-}"
  local suffix=0 candidate=""

  [ -n "$cname" ] || return 1

  while [ "$suffix" -lt 100 ]; do
    if [ "$suffix" -eq 0 ]; then
      candidate="${cname}-rollback-$$"
    else
      candidate="${cname}-rollback-$$-${suffix}"
    fi
    if ! container_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    suffix=$((suffix + 1))
  done

  return 1
}

function _cleanup_runtime_stage_container_delete() {
  local cname="${1:-}"
  local domain="${2:-}" container_id="${3:-}" token="${4:-}"
  local backup_cname="" was_running="false" index=0
  local target="$cname"

  [ -n "$cname" ] || return 1
  if [ "$#" -ne 1 ]; then
    [ "$#" -eq 4 ] && [ -n "$domain" ] && [ -n "$container_id" ] && [ -n "$token" ] || return 1
    _backend_identity_inspect "$domain" "$container_id" "$token" || return 1
    target="$container_id"
    [ "${BACKEND_CONTAINER_STATUS:-}" != running ] || was_running=true
  elif ! container_exists "$cname"; then
    return 0
  fi

  _cleanup_runtime_init_staged_deletes
  if ! backup_cname="$(_cleanup_runtime_backup_name "$cname")"; then
    echo "[Error] Failed to reserve a rollback container name for '${cname}'." >&2
    return 1
  fi

  if ! docker rename "$target" "$backup_cname" >/dev/null 2>&1; then
    echo "[Error] Failed to stage container '${cname}' for cleanup rollback." >&2
    return 1
  fi

  if [ -z "$container_id" ]; then
    target="$backup_cname"
    if container_running "$target"; then
      was_running="true"
    fi
  fi

  # Save backend proof before stopping: a failed stop or recovery must retain
  # the immutable identity even after the transaction removes its state row.
  if [ -n "$container_id" ]; then
    index="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"
    CLEANUP_RUNTIME_DELETE_ORIGINALS[$index]="$cname"
    CLEANUP_RUNTIME_DELETE_BACKUPS[$index]="$backup_cname"
    CLEANUP_RUNTIME_DELETE_WAS_RUNNING[$index]="$was_running"
    CLEANUP_RUNTIME_DELETE_IDS[$index]="$container_id"
    CLEANUP_RUNTIME_DELETE_DOMAINS[$index]="$domain"
    CLEANUP_RUNTIME_DELETE_TOKENS[$index]="$token"
    CLEANUP_RUNTIME_DELETE_COUNT=$((index + 1))
    rollback_pre_hook_add "_cleanup_runtime_restore_staged_deletes_if_needed"
  fi

  if [ "$was_running" = "true" ]; then
    if ! docker stop "$target" >/dev/null 2>&1; then
      if [ -n "$container_id" ]; then
        _cleanup_runtime_restore_backend_delete "$cname" "$container_id" "$domain" "$token" "$was_running" || true
      else
        docker rename "$backup_cname" "$cname" >/dev/null 2>&1 || true
      fi
      echo "[Error] Failed to stop staged cleanup container '${backup_cname}'." >&2
      return 1
    fi
  fi

  [ -z "$container_id" ] || return 0
  index="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"
  CLEANUP_RUNTIME_DELETE_ORIGINALS[$index]="$cname"
  CLEANUP_RUNTIME_DELETE_BACKUPS[$index]="$backup_cname"
  CLEANUP_RUNTIME_DELETE_WAS_RUNNING[$index]="$was_running"
  CLEANUP_RUNTIME_DELETE_IDS[$index]=""
  CLEANUP_RUNTIME_DELETE_DOMAINS[$index]=""
  CLEANUP_RUNTIME_DELETE_TOKENS[$index]=""
  CLEANUP_RUNTIME_DELETE_COUNT=$((index + 1))
  rollback_pre_hook_add "_cleanup_runtime_restore_staged_deletes_if_needed"
}

function _cleanup_runtime_restore_backend_delete() {
  local original="${1:-}" container_id="${2:-}" domain="${3:-}" token="${4:-}" was_running="${5:-false}"
  local current_name=""

  _backend_identity_inspect "$domain" "$container_id" "$token" || return 1
  if ! docker rename "$container_id" "$original" >/dev/null 2>&1; then
    # A retry may already have restored this ID. Inspect that ID, never adopt
    # or start a replacement which now occupies the original name.
    current_name="$(docker inspect -f '{{.Name}}' "$container_id" 2>/dev/null || exit "$?")" || return 1
    if [ "$current_name" != "/$original" ]; then
      echo "[Error] Failed to restore backend container '$container_id' as '$original'; retaining its rollback container." >&2
      return 1
    fi
  fi
  if [ "$was_running" = "true" ]; then
    _backend_identity_inspect "$domain" "$container_id" "$token" || return 1
    if ! docker start "$container_id" >/dev/null 2>&1; then
      echo "[Error] Failed to restart backend container '$container_id'; cleanup rollback is incomplete." >&2
      return 1
    fi
  fi
}

function _cleanup_runtime_restore_staged_deletes_if_needed() {
  local count="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"

  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
    return 0
  fi

  _cleanup_runtime_restore_staged_deletes_from_index "${CLEANUP_RUNTIME_DELETE_NEXT_INDEX:-0}" || return 1
  _cleanup_runtime_clear_staged_deletes
}

function _cleanup_runtime_restore_staged_deletes_from_index() {
  local start_index="${1:-0}"
  local count="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"
  local index=0 original="" backup="" was_running="false"
  local container_id="" domain="" token="" failed=false

  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
    return 0
  fi

  if ! [[ "$start_index" =~ ^[0-9]+$ ]] || [ "$start_index" -lt 0 ]; then
    start_index=0
  fi
  if [ "$start_index" -lt "${CLEANUP_RUNTIME_DELETE_NEXT_INDEX:-0}" ]; then
    start_index="${CLEANUP_RUNTIME_DELETE_NEXT_INDEX:-0}"
  fi
  if [ "$start_index" -ge "$count" ]; then
    return 0
  fi

  index=$((count - 1))
  while [ "$index" -ge "$start_index" ]; do
    original="${CLEANUP_RUNTIME_DELETE_ORIGINALS[$index]-}"
    backup="${CLEANUP_RUNTIME_DELETE_BACKUPS[$index]-}"
    was_running="${CLEANUP_RUNTIME_DELETE_WAS_RUNNING[$index]-false}"
    container_id="${CLEANUP_RUNTIME_DELETE_IDS[$index]-}"
    domain="${CLEANUP_RUNTIME_DELETE_DOMAINS[$index]-}"
    token="${CLEANUP_RUNTIME_DELETE_TOKENS[$index]-}"

    if [ -n "$container_id" ]; then
      _cleanup_runtime_restore_backend_delete "$original" "$container_id" "$domain" "$token" "$was_running" || failed=true
    else
      if [ -n "$backup" ] && container_exists "$backup" && ! container_exists "$original"; then
        docker rename "$backup" "$original" >/dev/null 2>&1 || true
      fi

      if [ "$was_running" = "true" ] && [ -n "$original" ] && container_exists "$original"; then
        docker start "$original" >/dev/null 2>&1 || true
      fi
    fi

    index=$((index - 1))
  done
  [ "$failed" = false ]
}

# Final deletion runs after the original state transaction commits. Recover
# proof for only the remaining containers in a new, locked state transaction;
# a concurrent new identity must never be overwritten by old recovery state.
function _cleanup_runtime_preserve_backend_identities_from_index() {
  local index="${1:-0}" count="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"
  local first_index="$index" domain="" container_id="" token="" has_backend=false
  if [ "$first_index" -lt "${CLEANUP_RUNTIME_DELETE_NEXT_INDEX:-0}" ]; then
    first_index="${CLEANUP_RUNTIME_DELETE_NEXT_INDEX:-0}"
  fi
  for ((index = first_index; index < count; index++)); do
    [ -z "${CLEANUP_RUNTIME_DELETE_IDS[$index]-}" ] || has_backend=true
  done
  [ "$has_backend" = true ] || return 0
  if transaction_is_active; then
    echo "[Error] Refusing post-cleanup identity recovery before the original transaction commits." >&2
    return 1
  fi
  # This recovery transaction restores saved proof only. Its rollback must not
  # recursively invoke the original runtime recovery hook.
  rollback_pre_hook_remove "_cleanup_runtime_restore_staged_deletes_if_needed"
  begin_transaction_return cleanup_backend_identity_recovery "$CONFIG_DIR" || return 1
  if ! _backend_identity_read "" true; then
    transaction_return_failure
    return 1
  fi
  for ((index = first_index; index < count; index++)); do
    container_id="${CLEANUP_RUNTIME_DELETE_IDS[$index]-}"
    [ -n "$container_id" ] || continue
    domain="${CLEANUP_RUNTIME_DELETE_DOMAINS[$index]-}"
    token="${CLEANUP_RUNTIME_DELETE_TOKENS[$index]-}"
    if ! _backend_identity_read "$domain" true; then
      transaction_return_failure
      return 1
    fi
    if [ "$BACKEND_IDENTITY_FOUND" -eq 1 ] &&
      { [ "$BACKEND_IDENTITY_ID" != "$container_id" ] || [ "$BACKEND_IDENTITY_TOKEN" != "$token" ]; }; then
      echo "[Error] A new saved identity conflicts with cleanup recovery for backend '$domain'; retaining it unchanged." >&2
      transaction_return_failure
      return 1
    fi
  done
  for ((index = first_index; index < count; index++)); do
    container_id="${CLEANUP_RUNTIME_DELETE_IDS[$index]-}"
    [ -n "$container_id" ] || continue
    if ! _backend_identity_store "${CLEANUP_RUNTIME_DELETE_DOMAINS[$index]-}" "$container_id" "${CLEANUP_RUNTIME_DELETE_TOKENS[$index]-}"; then
      transaction_return_failure
      return 1
    fi
  done
  TRANSACTION_COMPLETION_FAILURE_MODE="return" end_transaction_success || return 1
}

function _cleanup_runtime_recover_finalization_failure() {
  local index="${1:-0}" proof_saved=true runtime_restored=true
  if ! _cleanup_runtime_preserve_backend_identities_from_index "$index"; then
    proof_saved=false
    echo "[Error] Could not persist remaining backend identities after cleanup; retaining in-memory recovery proof." >&2
    if [ -n "${CLEANUP_RUNTIME_DELETE_RECOVERY_BACKUP:-}" ]; then
      echo "[Error] Original cleanup state remains in backup: $CLEANUP_RUNTIME_DELETE_RECOVERY_BACKUP" >&2
    fi
  fi
  _cleanup_runtime_restore_staged_deletes_from_index "$index" || runtime_restored=false
  if [ "$proof_saved" = true ] && [ "$runtime_restored" = true ]; then
    _cleanup_runtime_clear_staged_deletes
    return 0
  fi
  return 1
}

function _cleanup_runtime_finalize_staged_deletes() {
  local count="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"
  local index=0 original="" backup="" delete_target="" was_running="false"
  local container_id="" domain="" token="" identity_status=0

  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
    _cleanup_runtime_clear_staged_deletes
    return 0
  fi

  index="${CLEANUP_RUNTIME_DELETE_NEXT_INDEX:-0}"
  while [ "$index" -lt "$count" ]; do
    original="${CLEANUP_RUNTIME_DELETE_ORIGINALS[$index]-}"
    backup="${CLEANUP_RUNTIME_DELETE_BACKUPS[$index]-}"
    was_running="${CLEANUP_RUNTIME_DELETE_WAS_RUNNING[$index]-false}"
    container_id="${CLEANUP_RUNTIME_DELETE_IDS[$index]-}"
    domain="${CLEANUP_RUNTIME_DELETE_DOMAINS[$index]-}"
    token="${CLEANUP_RUNTIME_DELETE_TOKENS[$index]-}"
    if [ -n "$container_id" ]; then
      identity_status=0
      _backend_identity_inspect "$domain" "$container_id" "$token" || identity_status=$?
      if [ "$identity_status" -eq 2 ]; then
        index=$((index + 1))
        CLEANUP_RUNTIME_DELETE_NEXT_INDEX="$index"
        continue
      fi
      if [ "$identity_status" -eq 0 ]; then
        if remove_container_and_anonymous_volumes "$container_id" >/dev/null 2>&1; then
          echo "[Info] Removed container '${original}'."
          index=$((index + 1))
          CLEANUP_RUNTIME_DELETE_NEXT_INDEX="$index"
          continue
        fi
        identity_status=0
        _backend_identity_inspect "$domain" "$container_id" "$token" || identity_status=$?
        if [ "$identity_status" -eq 2 ]; then
          index=$((index + 1))
          CLEANUP_RUNTIME_DELETE_NEXT_INDEX="$index"
          continue
        fi
      fi
      _cleanup_runtime_recover_finalization_failure "$index" || true
      echo "[Error] Failed to safely remove staged backend container '${container_id}'." >&2
      return 1
    fi
    delete_target="$backup"
    if [ -n "$backup" ] && container_exists "$backup"; then
      if [ -n "$original" ]; then
        if ! docker rename "$backup" "$original" >/dev/null 2>&1; then
          _cleanup_runtime_recover_finalization_failure "$index" || true
          echo "[Error] Failed to restore staged cleanup container name '${backup}' to '${original}' before final removal." >&2
          return 1
        fi
        delete_target="$original"
      fi
      if ! remove_container_and_anonymous_volumes "$delete_target" >/dev/null 2>&1; then
        _cleanup_runtime_recover_finalization_failure "$index" || true
        echo "[Error] Failed to permanently remove staged cleanup container '${delete_target}'." >&2
        return 1
      fi
      if [ -n "$original" ]; then
        echo "[Info] Removed container '${original}'."
      elif [ -n "$delete_target" ]; then
        echo "[Info] Removed container '${delete_target}'."
      fi
    fi
    index=$((index + 1))
    CLEANUP_RUNTIME_DELETE_NEXT_INDEX="$index"
  done

  _cleanup_runtime_clear_staged_deletes
}
