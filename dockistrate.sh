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

# Loader for module sourcing
source "${SCRIPT_DIR}/lib/loader.sh"

# Source initialization dependencies first
_source_modules \
  "${SCRIPT_DIR}/lib/logging.sh" \
  "${SCRIPT_DIR}/lib/utils.sh"

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
  if [ "${#SELECTED_ARGS[@]}" -gt 0 ]; then
    run_command "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
  else
    run_command "$SELECTED_CMD"
  fi
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

if [ "$VERBOSE" = true ] && [ "$DOCKISTRATE_PRE_RUNTIME_COMMAND" != true ]; then
  # Log command traces to the main log file and echo them to the console
  # Prepare log file for tracing; gracefully degrade if not writable
  _verbose_log_ready=true
  if command -v ensure_log_writable >/dev/null 2>&1; then
    ensure_log_writable "$LOG_FILE" || _verbose_log_ready=false
  fi
  if [ "$_verbose_log_ready" = true ] && { touch "$LOG_FILE" 2>/dev/null && [ -w "$LOG_FILE" ]; }; then
    exec 3>>"$LOG_FILE"
    export BASH_XTRACEFD=3
  else
    echo "[Warn] Cannot write to $LOG_FILE; verbose output will not be logged."
  fi
  unset _verbose_log_ready
  PS4='+ $(date "+%Y-%m-%d %H:%M:%S") [CMD] '
  set -x
  log_msg "Verbose mode enabled"
fi

if [ "$INTERACTIVE" = true ] && [ "$#" -eq 0 ]; then
  while true; do
    interactive_picker || break
    if ! dockistrate_run_selected_command; then
      :
    else
      if declare -F interactive_record_recent_command >/dev/null 2>&1 &&
        ! { declare -F dockistrate_command_skips_runtime_prep >/dev/null 2>&1 &&
          dockistrate_command_skips_runtime_prep "${SELECTED_CMD:-}"; }; then
        if [ "${#SELECTED_ARGS[@]}" -gt 0 ]; then
          interactive_record_recent_command "$SELECTED_CMD" "${SELECTED_ARGS[@]}" || true
        else
          interactive_record_recent_command "$SELECTED_CMD" || true
        fi
      fi
    fi
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
if ! dockistrate_command_skips_runtime_prep "$CMD" "$@"; then
  dockistrate_prepare_runtime || exit 1
fi
run_command "$CMD" "$@"
