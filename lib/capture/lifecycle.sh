# shellcheck shell=bash

# Capture replacement must hold the same lock as configuration/TLS changes.
# The prep lock can be promoted into a TLS transaction; its finalization only
# releases it after Docker has finished binding the capture directory.
function _capture_runtime_lock_exit_cleanup() {
  local status="${1:-1}"
  if [ "${CAPTURE_TLS_LAUNCH_ACTIVE:-false}" = true ]; then
    _capture_tls_launch_abort || true
  fi
  _config_end_runtime_prep_lock_if_started "$_capture_lock_started" || true
  return "$status"
}

function _capture_with_runtime_lock() {
  local _capture_lock_started=false _capture_lock_status=0
  local _capture_lock_exit_trap="" body="" action="" signal_name=""
  local -a _capture_lock_default_signals=()
  # Direct-source tests/callers get the same lock and trap helpers as the loader.
  if ! declare -F _config_begin_runtime_prep_lock_if_needed >/dev/null 2>&1; then
    # shellcheck source=lib/backups.sh
    source "$(dirname "${BASH_SOURCE[0]}")/../backups.sh" || return 1
  fi
  _config_begin_runtime_prep_lock_if_needed _capture_lock_started || return 1
  if [ "$_capture_lock_started" = true ]; then
    _capture_lock_exit_trap="$(trap -p EXIT)"
    if ! _restore_intake_trap_is_default "$_capture_lock_exit_trap" EXIT; then
      if ! _restore_intake_trap_action body "$_capture_lock_exit_trap" EXIT; then
        _config_end_runtime_prep_lock_if_started true || true
        return 1
      fi
    fi
    action='_capture_runtime_lock_exit_cleanup "$?" && :'$'\n'"$body"
    trap -- "$action" EXIT
    for signal_name in HUP INT TERM; do
      if _restore_intake_trap_is_default "$(trap -p "$signal_name")" "$signal_name"; then
        _capture_lock_default_signals+=("$signal_name")
        case "$signal_name" in
        HUP) trap 'exit 129' HUP ;;
        INT) trap 'exit 130' INT ;;
        TERM) trap 'exit 143' TERM ;;
        esac
      fi
    done
  fi

  "$@" || _capture_lock_status=$?
  if [ "$_capture_lock_started" = true ]; then
    # The TLS launcher restores this wrapper's trap before returning.
    if [ "${#_capture_lock_default_signals[@]}" -gt 0 ]; then
      trap '' "${_capture_lock_default_signals[@]}"
    fi
    if ! _config_end_runtime_prep_lock_if_started true; then
      [ "$_capture_lock_status" -ne 0 ] || _capture_lock_status=1
    fi
    _restore_intake_restore_trap "$_capture_lock_exit_trap" EXIT || _capture_lock_status=1
    if [ "${#_capture_lock_default_signals[@]}" -gt 0 ]; then
      trap - "${_capture_lock_default_signals[@]}"
    fi
  fi
  return "$_capture_lock_status"
}

function _capture_existing_container_id() {
  local output_var="${1:-}" result=""
  require_valid_var_name "$output_var" || return 1
  # An empty successful listing proves absence. A failed inspect/list does not.
  if ! result="$(docker ps -a --no-trunc --filter 'name=^/nginx-capture$' --format '{{.ID}}')"; then
    echo "[Error] Unable to determine whether an existing capture is still running." >&2
    return 1
  fi
  if [ -n "$result" ] && ! [[ "$result" =~ ^[0-9a-f]{64}$ ]]; then
    echo "[Error] Unable to identify the existing capture container safely." >&2
    return 1
  fi
  printf -v "$output_var" '%s' "$result"
}

function _capture_remove_existing() {
  local output_var="${1:-}" graceful="${2:-false}" capture_id="" remaining_id=""
  require_valid_var_name "$output_var" || return 1
  printf -v "$output_var" '%s' false
  _capture_existing_container_id capture_id || return 1
  [ -n "$capture_id" ] || return 0
  if [ "$graceful" = true ] && ! docker stop "$capture_id" >/dev/null; then
    echo "[Error] Failed to stop the previous packet capture; its output was left untouched." >&2
    return 1
  fi
  if ! remove_container_and_anonymous_volumes "$capture_id" >/dev/null; then
    echo "[Error] Failed to remove the previous packet capture; refusing to prepare a new output directory." >&2
    return 1
  fi
  _capture_existing_container_id remaining_id || return 1
  if [ -n "$remaining_id" ]; then
    echo "[Error] A capture container still exists; refusing to continue capture replacement." >&2
    return 1
  fi
  printf -v "$output_var" '%s' true
}
