# shellcheck shell=bash

function _cleanup_runtime_clear_staged_deletes() {
  rollback_pre_hook_remove "_cleanup_runtime_restore_staged_deletes_if_needed"
  unset CLEANUP_RUNTIME_DELETE_STATE_INITIALIZED
  unset CLEANUP_RUNTIME_DELETE_COUNT
  unset CLEANUP_RUNTIME_DELETE_ORIGINALS
  unset CLEANUP_RUNTIME_DELETE_BACKUPS
  unset CLEANUP_RUNTIME_DELETE_WAS_RUNNING
}

function _cleanup_runtime_init_staged_deletes() {
  if [ "${CLEANUP_RUNTIME_DELETE_STATE_INITIALIZED:-false}" = "true" ]; then
    return 0
  fi

  CLEANUP_RUNTIME_DELETE_STATE_INITIALIZED="true"
  CLEANUP_RUNTIME_DELETE_COUNT=0
  CLEANUP_RUNTIME_DELETE_ORIGINALS=()
  CLEANUP_RUNTIME_DELETE_BACKUPS=()
  CLEANUP_RUNTIME_DELETE_WAS_RUNNING=()
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
  local backup_cname="" was_running="false" index=0

  [ -n "$cname" ] || return 1
  if ! container_exists "$cname"; then
    return 0
  fi

  _cleanup_runtime_init_staged_deletes
  if ! backup_cname="$(_cleanup_runtime_backup_name "$cname")"; then
    echo "[Error] Failed to reserve a rollback container name for '${cname}'." >&2
    return 1
  fi

  if ! docker rename "$cname" "$backup_cname" >/dev/null 2>&1; then
    echo "[Error] Failed to stage container '${cname}' for cleanup rollback." >&2
    return 1
  fi

  if container_running "$backup_cname"; then
    if ! docker stop "$backup_cname" >/dev/null 2>&1; then
      docker rename "$backup_cname" "$cname" >/dev/null 2>&1 || true
      echo "[Error] Failed to stop staged cleanup container '${backup_cname}'." >&2
      return 1
    fi
    was_running="true"
  fi

  index="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"
  CLEANUP_RUNTIME_DELETE_ORIGINALS[$index]="$cname"
  CLEANUP_RUNTIME_DELETE_BACKUPS[$index]="$backup_cname"
  CLEANUP_RUNTIME_DELETE_WAS_RUNNING[$index]="$was_running"
  CLEANUP_RUNTIME_DELETE_COUNT=$((index + 1))
  rollback_pre_hook_add "_cleanup_runtime_restore_staged_deletes_if_needed"
}

function _cleanup_runtime_restore_staged_deletes_if_needed() {
  local count="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"

  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
    return 0
  fi

  _cleanup_runtime_restore_staged_deletes_from_index 0
  _cleanup_runtime_clear_staged_deletes
}

function _cleanup_runtime_restore_staged_deletes_from_index() {
  local start_index="${1:-0}"
  local count="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"
  local index=0 original="" backup="" was_running="false"

  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
    return 0
  fi

  if ! [[ "$start_index" =~ ^[0-9]+$ ]] || [ "$start_index" -lt 0 ]; then
    start_index=0
  fi
  if [ "$start_index" -ge "$count" ]; then
    return 0
  fi

  index=$((count - 1))
  while [ "$index" -ge "$start_index" ]; do
    original="${CLEANUP_RUNTIME_DELETE_ORIGINALS[$index]-}"
    backup="${CLEANUP_RUNTIME_DELETE_BACKUPS[$index]-}"
    was_running="${CLEANUP_RUNTIME_DELETE_WAS_RUNNING[$index]-false}"

    if [ -n "$backup" ] && container_exists "$backup" && ! container_exists "$original"; then
      docker rename "$backup" "$original" >/dev/null 2>&1 || true
    fi

    if [ "$was_running" = "true" ] && [ -n "$original" ] && container_exists "$original"; then
      docker start "$original" >/dev/null 2>&1 || true
    fi

    index=$((index - 1))
  done
}

function _cleanup_runtime_finalize_staged_deletes() {
  local count="${CLEANUP_RUNTIME_DELETE_COUNT:-0}"
  local index=0 original="" backup="" delete_target="" was_running="false"

  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
    _cleanup_runtime_clear_staged_deletes
    return 0
  fi

  while [ "$index" -lt "$count" ]; do
    original="${CLEANUP_RUNTIME_DELETE_ORIGINALS[$index]-}"
    backup="${CLEANUP_RUNTIME_DELETE_BACKUPS[$index]-}"
    was_running="${CLEANUP_RUNTIME_DELETE_WAS_RUNNING[$index]-false}"
    delete_target="$backup"
    if [ -n "$backup" ] && container_exists "$backup"; then
      if [ -n "$original" ]; then
        if ! docker rename "$backup" "$original" >/dev/null 2>&1; then
          _cleanup_runtime_restore_staged_deletes_from_index "$index"
          _cleanup_runtime_clear_staged_deletes
          echo "[Error] Failed to restore staged cleanup container name '${backup}' to '${original}' before final removal." >&2
          return 1
        fi
        delete_target="$original"
      fi
      if ! remove_container_and_anonymous_volumes "$delete_target" >/dev/null 2>&1; then
        _cleanup_runtime_restore_staged_deletes_from_index "$index"
        _cleanup_runtime_clear_staged_deletes
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
  done

  _cleanup_runtime_clear_staged_deletes
}
