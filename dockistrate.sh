#!/usr/bin/env bash
set -Eeuo pipefail
#
# dockistrate.sh - Main entry for the Docker-based webserver manager
# Splits functionality into multiple modules for easier maintenance.

# Determine script base directory so the tool can be run from anywhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERSION_FILE="${SCRIPT_DIR}/VERSION"
if [[ -r "$VERSION_FILE" ]]; then
  DOCKISTRATE_VERSION="$(<"$VERSION_FILE")"
else
  echo "[Error] VERSION file is missing or unreadable." >&2
  exit 1
fi
readonly VERSION_FILE
readonly DOCKISTRATE_VERSION

# Source the config first (so we know GLOBAL_SETTINGS_FILE, etc.)
source "${SCRIPT_DIR}/lib/config.sh"

# Verbose output disabled by default
VERBOSE=false
INTERACTIVE=false

# Selected command and arguments when using interactive mode
SELECTED_CMD=""
SELECTED_ARGS=()
CURRENT_CMD=""
CURRENT_ARGS=()
DOCKISTRATE_INTERACTIVE_XTRACE_STATE=""
DOCKISTRATE_INTERACTIVE_XTRACE_SUPPRESSED=false
DOCKISTRATE_VERBOSE_LOGGING_ACTIVE=false
DOCKISTRATE_VERBOSE_TRACE_ROUTE=""

# Loader for module sourcing
source "${SCRIPT_DIR}/lib/loader.sh"

# Source initialization dependencies first
_source_modules \
  "${SCRIPT_DIR}/lib/logging.sh" \
  "${SCRIPT_DIR}/lib/utils.sh" \
  "${SCRIPT_DIR}/lib/domain_config.sh"

# Source eager modules required for command dispatch and deferred prep.
_source_modules \
  "${SCRIPT_DIR}/lib/dependencies.sh" \
  "${SCRIPT_DIR}/lib/cli.sh"

# Defer loading heavy command modules and runtime validation until a real command runs.
DOCKISTRATE_DEFERRED_MODULES_LOADED=false
DOCKISTRATE_RUNTIME_PREPARED=false
DOCKISTRATE_PRE_RUNTIME_COMMAND=false

function _dockistrate_source_deferred_modules() {
  if [ "${DOCKISTRATE_DEFERRED_MODULES_LOADED}" = true ]; then
    return 0
  fi

  _source_modules \
    "${SCRIPT_DIR}/lib/backends.sh" \
    "${SCRIPT_DIR}/lib/nginx.sh" \
    "${SCRIPT_DIR}/lib/nginx_directives.sh" \
    "${SCRIPT_DIR}/lib/ports.sh" \
    "${SCRIPT_DIR}/lib/certs.sh" \
    "${SCRIPT_DIR}/lib/backups.sh" \
    "${SCRIPT_DIR}/lib/tokens.sh" \
    "${SCRIPT_DIR}/lib/access_log.sh" \
    "${SCRIPT_DIR}/lib/clean_uninstall.sh" \
    "${SCRIPT_DIR}/lib/global_settings.sh" \
    "${SCRIPT_DIR}/lib/http_version.sh" \
    "${SCRIPT_DIR}/lib/tls.sh" \
    "${SCRIPT_DIR}/lib/mtls.sh" \
    "${SCRIPT_DIR}/lib/headers.sh" \
    "${SCRIPT_DIR}/lib/security_rules.sh" \
    "${SCRIPT_DIR}/lib/capture.sh" \
    "${SCRIPT_DIR}/lib/permissions.sh"
  DOCKISTRATE_DEFERRED_MODULES_LOADED=true
}

function dockistrate_prepare_runtime() {
  if [ "${DOCKISTRATE_RUNTIME_PREPARED}" = true ]; then
    return 0
  fi

  _dockistrate_source_deferred_modules || return 1
  check_dependencies || return 1
  bootstrap_config_runtime || return 1
  cleanup_leftovers
  DOCKISTRATE_RUNTIME_PREPARED=true
}

function dockistrate_run_selected_command() {
  if [ "${VERBOSE:-false}" = true ]; then
    if [ "${#SELECTED_ARGS[@]}" -gt 0 ]; then
      dockistrate_disable_interactive_xtrace_if_needed "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
    else
      dockistrate_disable_interactive_xtrace_if_needed "$SELECTED_CMD"
    fi
  fi

  if [ "${#SELECTED_ARGS[@]}" -gt 0 ]; then
    run_command "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
  else
    run_command "$SELECTED_CMD"
  fi
}

function dockistrate_start_verbose_logging() {
  if [ "${VERBOSE:-false}" != true ] ||
    [ "${DOCKISTRATE_VERBOSE_LOGGING_ACTIVE:-false}" = true ]; then
    return 0
  fi

  local log_ready=true
  if command -v ensure_log_writable >/dev/null 2>&1; then
    ensure_log_writable "$LOG_FILE" || log_ready=false
  fi
  if [ "$log_ready" = true ] && { touch "$LOG_FILE" 2>/dev/null && [ -w "$LOG_FILE" ]; }; then
    if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 1))); then
      exec 3>>"$LOG_FILE"
      export BASH_XTRACEFD=3
      DOCKISTRATE_VERBOSE_TRACE_ROUTE=xtracefd
    else
      # Bash 3 ignores BASH_XTRACEFD. Keep the original stderr available so
      # a later pre-runtime command can run without appending to this log.
      exec 3>&2
      exec 2> >(tee -a "$LOG_FILE" >&3)
      DOCKISTRATE_VERBOSE_TRACE_ROUTE=stderr
    fi
  else
    echo "[Warn] Cannot write to $LOG_FILE; verbose output will not be logged."
  fi
  DOCKISTRATE_VERBOSE_LOGGING_ACTIVE=true
  xtrace_start
  log_msg "Verbose mode enabled"
}

function dockistrate_stop_verbose_logging() {
  local trace_state=""
  xtrace_disable trace_state
  case "${DOCKISTRATE_VERBOSE_TRACE_ROUTE:-}" in
  xtracefd)
    # Unsetting BASH_XTRACEFD closes its descriptor without redirecting stderr.
    unset BASH_XTRACEFD
    ;;
  stderr)
    exec 2>&3
    exec 3>&-
    ;;
  esac
  DOCKISTRATE_VERBOSE_TRACE_ROUTE=""
  DOCKISTRATE_VERBOSE_LOGGING_ACTIVE=false
  DOCKISTRATE_INTERACTIVE_XTRACE_STATE=""
  DOCKISTRATE_INTERACTIVE_XTRACE_SUPPRESSED=false
}

function dockistrate_disable_interactive_xtrace_if_needed() {
  if [ "${VERBOSE:-false}" != true ]; then
    return 0
  fi

  if [ -n "${1:-}" ]; then
    if dockistrate_command_skips_runtime_prep "$@"; then
      dockistrate_stop_verbose_logging
      return 0
    fi
    if [ "${DOCKISTRATE_VERBOSE_LOGGING_ACTIVE:-false}" != true ]; then
      dockistrate_start_verbose_logging
      DOCKISTRATE_INTERACTIVE_XTRACE_STATE=""
      DOCKISTRATE_INTERACTIVE_XTRACE_SUPPRESSED=false
    fi
  elif [ "${DOCKISTRATE_VERBOSE_LOGGING_ACTIVE:-false}" != true ]; then
    return 0
  fi
  if [ "${DOCKISTRATE_INTERACTIVE_XTRACE_SUPPRESSED:-false}" = true ]; then
    return 0
  fi

  xtrace_disable DOCKISTRATE_INTERACTIVE_XTRACE_STATE
  if dockistrate_redacted_xtrace_needed "$@"; then
    DOCKISTRATE_INTERACTIVE_XTRACE_SUPPRESSED=true
  else
    xtrace_restore "$DOCKISTRATE_INTERACTIVE_XTRACE_STATE"
    DOCKISTRATE_INTERACTIVE_XTRACE_STATE=""
  fi
}

function dockistrate_restore_interactive_xtrace_if_needed() {
  if [ "${DOCKISTRATE_INTERACTIVE_XTRACE_SUPPRESSED:-false}" = true ]; then
    xtrace_restore "$DOCKISTRATE_INTERACTIVE_XTRACE_STATE"
  fi
  DOCKISTRATE_INTERACTIVE_XTRACE_STATE=""
  DOCKISTRATE_INTERACTIVE_XTRACE_SUPPRESSED=false
}

function dockistrate_command_may_enable_redacted_visibility() {
  local cmd="${1:-}"
  shift || true

  [ "$cmd" = "set-visibility-policy" ] || return 1
  if [ "$#" -eq 0 ] || [ "${1:-}" = "redacted" ]; then
    return 0
  fi
  return 1
}

function dockistrate_redacted_xtrace_needed() {
  local cmd="${1:-}"
  shift || true

  [ "${VERBOSE:-false}" = true ] || return 1
  declare -F _run_command_has_sensitive_args >/dev/null 2>&1 || return 1
  if dockistrate_command_may_enable_redacted_visibility "$cmd" "$@"; then
    return 0
  fi
  if [ -s "${GLOBAL_SETTINGS_FILE:-}" ] && declare -F load_config >/dev/null 2>&1; then
    # An atomic load can reject settings before publishing their visibility
    # policy. Keep tracing suppressed until that policy is known to be valid.
    if ! load_config >/dev/null 2>&1; then
      return 0
    fi
  fi
  if declare -F operator_visibility_is_redacted >/dev/null 2>&1 &&
    operator_visibility_is_redacted; then
    return 0
  fi
  _run_command_has_sensitive_args "$cmd" "$@"
}

# Lightweight pre-scan to allow certain commands to run without Docker
if [ "$#" -gt 0 ]; then
  _first_cmd=""
  _second_cmd=""
  for _tok in "$@"; do
    case "$_tok" in
    -v | --verbose | -i | --interactive) continue ;;
    --version | version)
      _first_cmd="version"
      break
      ;;
    *)
      if [ -z "$_first_cmd" ]; then
        _first_cmd="$_tok"
        continue
      fi
      _second_cmd="$_tok"
      break
      ;;
    esac
  done
  if [ "${_first_cmd}" = "fix-permissions" ]; then
    export SKIP_DOCKER_CHECKS=true
  fi
  if declare -F dockistrate_command_skips_runtime_prep >/dev/null 2>&1 &&
    dockistrate_command_skips_runtime_prep "$_first_cmd" "$_second_cmd"; then
    DOCKISTRATE_PRE_RUNTIME_COMMAND=true
  fi
  if [ "${_first_cmd}" = "version" ]; then
    echo "$DOCKISTRATE_VERSION"
    exit 0
  fi
  unset _tok _first_cmd _second_cmd
fi

#######################################
# MAIN
#######################################

# Parse optional flags before command
while [[ $# -gt 0 && "$1" == -* ]]; do
  case "$1" in
  -v | --verbose)
    VERBOSE=true
    shift
    ;;
  -i | --interactive)
    INTERACTIVE=true
    shift
    ;;
  *)
    break
    ;;
  esac
done

if [ "$INTERACTIVE" = true ] && [ "$#" -eq 0 ]; then
  while true; do
    DOCKISTRATE_INTERACTIVE_XTRACE_STATE=""
    DOCKISTRATE_INTERACTIVE_XTRACE_SUPPRESSED=false
    dockistrate_disable_interactive_xtrace_if_needed
    if ! interactive_picker; then
      dockistrate_restore_interactive_xtrace_if_needed
      dockistrate_stop_verbose_logging
      break
    fi
    if ! dockistrate_run_selected_command; then
      :
    else
      if declare -F interactive_record_recent_command >/dev/null 2>&1 &&
        { ! { declare -F dockistrate_command_skips_runtime_prep >/dev/null 2>&1 &&
            dockistrate_command_skips_runtime_prep "${SELECTED_CMD:-}"; } ||
          dockistrate_command_repairs_headers "${SELECTED_CMD:-}" ||
          { [ "${SELECTED_CMD:-}" = restore-backup ] && [ "${DOCKISTRATE_RESTORE_COMPLETED:-false}" = true ]; }; }; then
        if [ "${#SELECTED_ARGS[@]}" -gt 0 ]; then
          interactive_record_recent_command "$SELECTED_CMD" "${SELECTED_ARGS[@]}" || true
        else
          interactive_record_recent_command "$SELECTED_CMD" || true
        fi
      fi
    fi
    dockistrate_restore_interactive_xtrace_if_needed
    dockistrate_stop_verbose_logging
    if [ "${SELECTED_CMD:-}" != "status" ] && [ "${SELECTED_CMD:-}" != "status-all" ]; then
      echo
      read -rp "Press Enter to continue..." _
    fi
  done
  exit 0
fi

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  usage
  exit 1
fi
shift || true
if [ "$VERBOSE" = true ] && [ "$DOCKISTRATE_PRE_RUNTIME_COMMAND" != true ]; then
  dockistrate_start_verbose_logging
fi
_dockistrate_xtrace_state=""
_dockistrate_suppress_sensitive_xtrace=false
if [ "$VERBOSE" = true ]; then
  xtrace_disable _dockistrate_xtrace_state
  if dockistrate_redacted_xtrace_needed "$CMD" "$@"; then
    _dockistrate_suppress_sensitive_xtrace=true
  else
    xtrace_restore "$_dockistrate_xtrace_state"
  fi
fi
if ! dockistrate_command_skips_runtime_prep "$CMD" "$@"; then
  if ! dockistrate_prepare_runtime; then
    if [ "$_dockistrate_suppress_sensitive_xtrace" = true ]; then
      xtrace_restore "$_dockistrate_xtrace_state"
    fi
    exit 1
  fi
fi
run_command "$CMD" "$@"
if [ "$_dockistrate_suppress_sensitive_xtrace" = true ]; then
  xtrace_restore "$_dockistrate_xtrace_state"
fi
