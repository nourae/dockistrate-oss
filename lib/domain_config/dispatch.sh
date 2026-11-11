# shellcheck shell=bash

function _domain_config_command_mutates() {
  case "${1:-}" in
  init-domain-config | validate-domain-config | apply-domain-config | migrate-state | \
    help | help-update | upgrade-preflight | fix-permissions | restore-backup | \
    status | status-all | check-config | list-* | show-* | tail-proxy-logs | \
    create-backup | start-capture | stop-capture) return 1 ;;
  *) return 0 ;;
  esac
}

function _domain_config_guard_pending() {
  local domain="${1:-}" root=""
  root="$(domain_config_root)"
  [ -d "$root/$domain/config" ] || [ -d "$root/$domain/runtime/applied" ] || return 0
  if ! domain_config_validate_source "$domain" "$root/$domain/config" >/dev/null 2>&1 ||
    ! _domain_config_same "$root/$domain/config" "$root/$domain/runtime/applied"; then
    DOMAIN_CONFIG_PENDING_DOMAIN="$domain"
    _domain_config_error "Unapplied or invalid edits exist at $root/$domain/config. Review and apply-domain-config $domain before changing it through a command."
    return 1
  fi
}

# Only command signatures identify domain operands. Values such as global
# header names or image references may contain dots without naming a target.
function _domain_config_guard_command_domain() {
  local domain="" resolution="${2:-own}"
  domain="$(normalize_domain "${1:-}")"
  is_valid_domain "$domain" || return 0
  if [ "$resolution" = primary ] && declare -F primary_domain_for >/dev/null 2>&1; then
    domain="$(primary_domain_for "$domain")" || return 1
  fi
  _domain_config_guard_pending "$domain"
}

function _domain_config_command_guard() {
  local command="${1:-}" argument="${2:-}" domain="" row=""
  unset DOMAIN_CONFIG_PENDING_DOMAIN
  if declare -F dockistrate_command_repairs_headers >/dev/null 2>&1 &&
    dockistrate_command_repairs_headers "$command"; then
    _domain_config_header_guard "$@"
    return $?
  fi
  case "$command" in
  remove-all-path-options | remove-all-backend-headers)
    if [ -z "$argument" ]; then
      while IFS= read -r domain; do _domain_config_guard_pending "$domain" || return 1; done < <(domain_config_list applied)
    else
      _domain_config_guard_command_domain "$argument" primary
    fi
    ;;
  *-all-backends | uninstall-all | renew-certs | remove-all-security-rules | disable-all-security-rules | enable-all-security-rules | \
    remove-all-acl | disable-all-acl | enable-all-acl | move-security-rule | move-acl-rule)
    while IFS= read -r domain; do _domain_config_guard_pending "$domain" || return 1; done < <(domain_config_list applied)
    ;;
  remove-backend | clean-all)
    domain="$(normalize_domain "$argument")"
    if [ "$command" = remove-backend ]; then
      # remove-backend accepts --yes before or after its single domain. Other
      # malformed signatures are left to the command's own usage validation.
      domain=""
      local removal_arg=""
      for removal_arg in "${@:2}"; do
        case "$removal_arg" in
        --yes) ;;
        -*) return 0 ;;
        *) [ -z "$domain" ] || return 0; domain="$(normalize_domain "$removal_arg")" ;;
        esac
      done
      is_valid_domain "$domain" || return 0
      if declare -F primary_domain_for >/dev/null 2>&1; then
        domain="$(primary_domain_for "$domain")" || return 1
      fi
    fi
    _domain_config_guard_pending "$domain" || return 1
    local dependent="" target="" root=""
    root="$(domain_config_root)"
    while IFS= read -r dependent; do
      [ -n "$dependent" ] || continue
      [ "$dependent" != "$domain" ] || continue
      target="$(domain_config_get "$root/$dependent/runtime/applied" domain.csv target)" || return 1
      [ "$target" != "$domain" ] || _domain_config_guard_pending "$dependent" || return 1
    done < <(domain_config_list applied)
    ;;
  remove-security-rule | enable-security-rule | disable-security-rule | update-security-rule | set-security-rule-mode | duplicate-security-rule)
    row="$(_sr_load_line "$argument")" || return 1
    csv_parse_line "$row" || return 1
    local rule_domain="${CSV_FIELDS[1]}" target_domain="" condition_args=0
    _domain_config_guard_pending "$rule_domain" || return 1
    if [ "$command" = update-security-rule ]; then
      shift 2
      while [ "$#" -gt 0 ]; do
        case "$1" in
        --domain)
          [ "$#" -ge 2 ] || return 0
          target_domain="$(normalize_domain "$2")"; shift 2
          ;;
        --action | --mode | --code | --reason | --loc)
          [ "$#" -ge 2 ] || return 0
          shift 2
          ;;
        --count)
          [ "$#" -ge 2 ] && [[ "$2" =~ ^(10|[1-9])$ ]] || return 0
          condition_args=$((2 + $2 * 4))
          [ "$#" -ge "$condition_args" ] || return 0
          shift "$condition_args"
          ;;
        *) return 0 ;;
        esac
      done
      if [ -n "$target_domain" ] && [ "$target_domain" != "$rule_domain" ]; then
        _domain_config_guard_command_domain "$target_domain"
      fi
    fi
    ;;
  remove-acl | enable-acl | disable-acl | update-acl)
    row="$(_sr_ip_load_line "$argument")" || return 1
    csv_parse_line "$row" || return 1
    _domain_config_guard_pending "${CSV_FIELDS[1]}"
    ;;
  set-nginx-directive | set-nginx-directive-raw | remove-nginx-directive | remove-all-nginx-directives)
    local scope=""
    scope="$(normalize_domain "${argument:-all}")"
    if [ "$scope" != all ]; then scope="$(nginx_directive_normalize_scope "$scope")" || return 1; fi
    case "$scope" in
    all)
      while IFS= read -r domain; do _domain_config_guard_pending "$domain" || return 1; done < <(domain_config_list applied)
      ;;
    global | stream-global) ;;
    *)
      _domain_config_guard_command_domain "${3:-}"
      ;;
    esac
    ;;
  start-backend | stop-backend | restart-backend | update-backend | replace-backend-network | \
    add-port | remove-port | update-port | set-port-redirect | remove-port-redirect | \
    add-path-option | update-path-option | remove-path-option | enable-ws | disable-ws)
    _domain_config_guard_command_domain "$argument" primary
    ;;
  add-backend | add-host-alias | remove-host-alias | add-dedicated-host | remove-dedicated-host | set-dedicated-host-inherit | \
    add-cert | replace-cert | remove-cert | add-backend-header | update-backend-header | remove-backend-header | \
    set-backend-hsts | set-backend-csp | set-backend-http-version | remove-backend-http-version | \
    set-backend-client-ip-header | remove-backend-client-ip-header | set-backend-proxy-ip-header | remove-backend-proxy-ip-header | \
    enable-backend-mtls | disable-backend-mtls | add-backend-client-cert | revoke-backend-client-cert | remove-backend-client-cert | \
    replace-backend-client-cert | export-backend-client-p12 | replace-backend-ca | remove-backend-ca | \
    set-backend-acl-policy | remove-backend-acl-policy | set-backend-acl-status | remove-backend-acl-status | \
    set-backend-security-rule-status | remove-backend-security-rule-status | add-acl | add-security-rule)
    _domain_config_guard_command_domain "$argument"
    ;;
  *)
    # Do not infer domain operands from arbitrary values of other commands.
    return 0
    ;;
  esac
}

function _domain_config_dispatch_locked() (
  local work="${1:-}" command="${2:-}" argument="" domain="" part="" root="" started_lock=false
  shift 2
  local DOMAIN_CONFIG_ACTIVE=true
  local DOMAIN_CONFIG_MUTATION_COMMAND="$command" DOMAIN_CONFIG_IDENTITY_ARG1="${1:-}" DOMAIN_CONFIG_IDENTITY_ARG2="${2:-}"
  local DOMAIN_CONFIG_DEFER_RENDER=true DOMAIN_CONFIG_RENDER_REQUESTED=false
  local DOMAIN_CONFIG_TERMINAL_UNINSTALL=false
  local DOMAIN_CONFIG_BACKEND_IDENTITY_MIGRATION=false
  local -a DOMAIN_CONFIG_TRANSACTION_TARGETS=()
  root="$(domain_config_root)"
  _config_begin_runtime_prep_lock_if_needed started_lock || return 1
  trap '_config_end_runtime_prep_lock_if_started "$started_lock"' EXIT
  domain_config_runtime_recover || return 1
  _domain_config_command_guard "$command" "$@" || return 1
  _domain_config_command_snapshot "$work" || return 1
  _domain_config_transaction_targets || return 1
  if [ "$command" = uninstall-all ]; then
    DOMAIN_CONFIG_TRANSACTION_TARGETS+=("$CAPTURE_DIR" "$ACME_WEBROOT_DIR")
    local physical=""
    for physical in "$root"/*; do
      [ -d "$physical" ] || continue
      _domain_config_validate_name "${physical##*/}" || return 1
      for part in runtime generated certs mtls; do DOMAIN_CONFIG_TRANSACTION_TARGETS+=("$physical/$part"); done
    done
  fi
  for argument in "$@"; do
    case "$argument" in --*) continue ;; esac
    domain="$(normalize_domain "$argument")"
    if is_valid_domain "$domain"; then
      for part in runtime generated certs mtls; do DOMAIN_CONFIG_TRANSACTION_TARGETS+=("$root/$domain/$part"); done
    fi
    break
  done
  begin_transaction "command_${command}" "${DOMAIN_CONFIG_TRANSACTION_TARGETS[@]}" || return 1
  # Proxy lifecycle commands inspect their immediate runtime result. Ordinary
  # configuration edits defer activation until the complete candidate validates.
  case "$command" in start-nginx | clean-all | uninstall-all) DOMAIN_CONFIG_DEFER_RENDER=false ;; esac
  _run_command_impl "$command" "$@" || return 1
  _domain_config_sync_command "$work" || return 1
  _domain_config_publish_generated || return 1
  if [ "$DOMAIN_CONFIG_TERMINAL_UNINSTALL" != true ]; then
    _domain_config_mark_cache || return 1
  fi
  _domain_config_source_verify || return 1
  end_transaction_success
)

function domain_config_dispatch() {
  local command="${1:-}" work="" status=0
  if ! _domain_config_command_mutates "$command"; then
    _run_command_impl "$@"
    return $?
  fi
  _domain_config_workspace work || return 1
  _domain_config_dispatch_locked "$work" "$@" || status=$?
  _domain_config_workspace_remove "$work" || true
  return "$status"
}
