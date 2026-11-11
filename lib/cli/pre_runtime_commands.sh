# shellcheck shell=bash

function dockistrate_command_repairs_headers() {
  case "${1:-}" in
  add-header | update-header | remove-header | remove-all-headers | \
    add-backend-header | update-backend-header | remove-backend-header | remove-all-backend-headers | \
    set-hsts | set-csp | set-backend-hsts | set-backend-csp) return 0 ;;
  *) return 1 ;;
  esac
}

# Header repairs need definitions and read-only choices before cache validation.
function dockistrate_prepare_header_command() {
  dockistrate_command_repairs_headers "${1:-}" || return 0
  if declare -F _dockistrate_source_deferred_modules >/dev/null 2>&1; then
    _dockistrate_source_deferred_modules || return 1
  fi
  # Prompt defaults and summaries must honor the persisted visibility policy
  # even though this command has not rebuilt or published any runtime cache.
  if [ -s "${GLOBAL_SETTINGS_FILE:-}" ] && declare -F load_config >/dev/null 2>&1; then
    load_config || return 1
  fi
}

function dockistrate_command_skips_runtime_prep() {
  local cmd="${1:-}"
  dockistrate_command_repairs_headers "$cmd" && return 0

  case "$cmd" in
  help | help-update | upgrade-preflight | fix-permissions | restore-backup | \
    init-domain-config | validate-domain-config | apply-domain-config | migrate-state)
    return 0
    ;;
  esac

  return 1
}
