# shellcheck shell=bash

function _review_domain_config_candidate() {
  local command="${1:-}"
  shift || true
  case "$command" in
  apply-domain-config)
    if declare -F apply_domain_config >/dev/null 2>&1; then
      apply_domain_config "$@" --dry-run || return 1
    fi
    ;;
  migrate-state)
    if declare -F migrate_state >/dev/null 2>&1; then
      migrate_state --dry-run "$@" || return 1
    fi
    ;;
  esac
}

# Returns 2 after applying pending files so every collector/recents path asks
# again against the new applied state instead of executing stale selections.
function _review_domain_config_pending() {
  local command="${1:-}" domain="" choice="" choose_status=0 review_status=0
  if declare -F dockistrate_prepare_header_command >/dev/null 2>&1; then
    dockistrate_prepare_header_command "$command" || return 1
  fi
  if ! declare -F domain_config_active >/dev/null 2>&1 || ! domain_config_active ||
    ! declare -F _domain_config_command_guard >/dev/null 2>&1 ||
    ! declare -F _domain_config_command_mutates >/dev/null 2>&1 ||
    ! _domain_config_command_mutates "$command"; then return 0; fi
  local DOMAIN_CONFIG_PENDING_DOMAIN=""
  if _domain_config_command_guard "$@" >/dev/null 2>&1; then return 0; fi
  domain="${DOMAIN_CONFIG_PENDING_DOMAIN:-}"
  if [ -z "$domain" ]; then
    _domain_config_command_guard "$@" || return 1
    return 0
  fi
  while :; do
    choose_status=0
    choose_option_with_context_status choose_status choice domain-config-pending \
      "Unapplied file changes for $domain. Resolve these before continuing with $command." \
      'Review file changes' 'Apply file changes' 'Cancel command'
    [ "$choose_status" -eq 0 ] || return 1
    case "$choice" in
    0)
      # An invalid draft remains selectable, so the operator can inspect the
      # validation error, fix its files, and review again without losing work.
      apply_domain_config "$domain" --dry-run || true
      ;;
    1)
      review_status=0
      review_command_before_run apply-domain-config "$domain" || review_status=$?
      [ "$review_status" -eq 0 ] || return "$review_status"
      apply_domain_config "$domain" || return 1
      printf '[Info] File changes applied. Review the command arguments again.\n'
      return 2
      ;;
    *) return 1 ;;
    esac
  done
}
