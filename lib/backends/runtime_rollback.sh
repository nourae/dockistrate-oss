# shellcheck shell=bash

function _backend_runtime_install_signal_traps() {
  [ "${BACKEND_RUNTIME_SIGNAL_TRAPS_ACTIVE:-false}" != true ] || return 0
  local signal_name=""
  BACKEND_RUNTIME_DEFAULT_SIGNALS=()
  BACKEND_RUNTIME_SIGNAL_TRAPS_ACTIVE=true
  for signal_name in HUP INT TERM; do
    if _restore_intake_trap_is_default "$(trap -p "$signal_name")" "$signal_name"; then
      BACKEND_RUNTIME_DEFAULT_SIGNALS+=("$signal_name")
      case "$signal_name" in
      HUP) trap '_backend_runtime_signal_exit 129' HUP ;;
      INT) trap '_backend_runtime_signal_exit 130' INT ;;
      TERM) trap '_backend_runtime_signal_exit 143' TERM ;;
      esac
    fi
  done
}

function _backend_runtime_clear_signal_traps() {
  if [ "${BACKEND_RUNTIME_SIGNAL_TRAPS_ACTIVE:-false}" = true ] &&
    [ "${#BACKEND_RUNTIME_DEFAULT_SIGNALS[@]}" -gt 0 ]; then
    trap - "${BACKEND_RUNTIME_DEFAULT_SIGNALS[@]}"
  fi
  unset BACKEND_RUNTIME_DEFAULT_SIGNALS BACKEND_RUNTIME_SIGNAL_TRAPS_ACTIVE
}

function _backend_runtime_quiet_signal_traps() {
  if [ "${BACKEND_RUNTIME_SIGNAL_TRAPS_ACTIVE:-false}" = true ] &&
    [ "${#BACKEND_RUNTIME_DEFAULT_SIGNALS[@]}" -gt 0 ]; then
    trap '' "${BACKEND_RUNTIME_DEFAULT_SIGNALS[@]}"
  fi
}

function _backend_runtime_signal_exit() {
  local status="${1:-1}" frame=""
  _backend_runtime_quiet_signal_traps
  # Do not interrupt or recursively enter an ordinary failure's recovery.
  for frame in "${FUNCNAME[@]}"; do
    case "$frame" in
    _rollback_handler | _rollback_handler_return | _rollback_handler_common) return 0 ;;
    esac
  done
  # Bash 3 may skip an EXIT trap in a signalled subshell whose parent had one.
  # Commit finalization also clears ERR/EXIT before the transaction is finished.
  # Explicit recovery covers both cases and preserves the signal exit status.
  if transaction_is_active; then
    _rollback_handler_common || true
  fi
  exit "$status"
}

# A launch token proves which container this attempt created, even when Docker
# returns an error after creation but before it prints a container ID.
function _backend_launch_new_token() {
  local token=""
  token="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom | LC_ALL=C tr -d ' \n')" || return 1
  [ "${#token}" -eq 32 ] || return 1
  case "$token" in *[!0-9a-f]*) return 1 ;; esac
  printf '%s\n' "$token"
}

function _backend_runtime_is_full_container_id() {
  local container_id="${1:-}"
  [ "${#container_id}" -eq 64 ] || return 1
  case "$container_id" in *[!0-9a-f]*) return 1 ;; esac
}

# A successful empty query distinguishes disappearance from a daemon failure.
function _backend_runtime_container_is_absent() {
  local container_id="${1:-}" existing=""
  _backend_runtime_is_full_container_id "$container_id" || return 1
  existing="$(docker ps -a --no-trunc --filter "id=$container_id" --format '{{.ID}}' || exit "$?")" || return 1
  [ -z "$existing" ]
}

function _backend_launch_cleanup() {
  local token="${1:-}" domain="${2:-}" container_ids="" container_id="" verify_status=0 failed=false
  [ -n "$token" ] || return 0
  [ "${#token}" -eq 32 ] || return 1
  case "$token" in *[!0-9a-f]*) return 1 ;; esac

  if ! container_ids="$(docker ps -a --no-trunc --filter "label=com.dockistrate.backend-launch=$token" --format '{{.ID}}' || exit "$?")"; then
    echo "[Error] Failed to find containers created by the backend launch; runtime rollback is incomplete." >&2
    return 1
  fi
  [ -n "$container_ids" ] || return 0

  while IFS= read -r container_id; do
    if ! _backend_runtime_is_full_container_id "$container_id"; then
      echo "[Error] Docker returned an invalid backend container identity; refusing runtime cleanup." >&2
      failed=true
      continue
    fi
    verify_status=0
    _backend_identity_inspect "$domain" "$container_id" "$token" || verify_status=$?
    if [ "$verify_status" -eq 2 ]; then
      continue
    elif [ "$verify_status" -ne 0 ]; then
      echo "[Error] Backend container ownership could not be verified; refusing runtime cleanup for '$container_id'." >&2
      failed=true
      continue
    fi
    if ! remove_container_and_anonymous_volumes "$container_id" >/dev/null 2>&1; then
      if _backend_runtime_container_is_absent "$container_id"; then
        continue
      fi
      echo "[Error] Failed to remove backend container '$container_id'; runtime rollback is incomplete." >&2
      failed=true
    fi
  done <<<"$container_ids"
  [ "$failed" = false ]
}
