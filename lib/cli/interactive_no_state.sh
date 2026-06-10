# shellcheck shell=bash

INTERACTIVE_COMMAND_UNAVAILABLE_KIND="${INTERACTIVE_COMMAND_UNAVAILABLE_KIND:-}"
INTERACTIVE_NO_STATE_ACTION="${INTERACTIVE_NO_STATE_ACTION:-}"
INTERACTIVE_COMMAND_DISPLAY_SUFFIX_CACHE_ACTIVE="${INTERACTIVE_COMMAND_DISPLAY_SUFFIX_CACHE_ACTIVE:-false}"
INTERACTIVE_STATE_HAS_BACKENDS_CACHE="${INTERACTIVE_STATE_HAS_BACKENDS_CACHE:-}"
INTERACTIVE_STATE_HAS_PORT_MAPPINGS_CACHE="${INTERACTIVE_STATE_HAS_PORT_MAPPINGS_CACHE:-}"
INTERACTIVE_STATE_HAS_CERTS_CACHE="${INTERACTIVE_STATE_HAS_CERTS_CACHE:-}"
INTERACTIVE_STATE_HAS_BACKEND_HEADERS_CACHE="${INTERACTIVE_STATE_HAS_BACKEND_HEADERS_CACHE:-}"
INTERACTIVE_STATE_HAS_MTLS_BACKENDS_CACHE="${INTERACTIVE_STATE_HAS_MTLS_BACKENDS_CACHE:-}"
INTERACTIVE_STATE_HAS_ACL_RULES_CACHE="${INTERACTIVE_STATE_HAS_ACL_RULES_CACHE:-}"
INTERACTIVE_STATE_HAS_SECURITY_RULES_CACHE="${INTERACTIVE_STATE_HAS_SECURITY_RULES_CACHE:-}"
INTERACTIVE_STATE_HAS_BACKUPS_CACHE="${INTERACTIVE_STATE_HAS_BACKUPS_CACHE:-}"

function _interactive_command_display_suffix_cache_reset() {
  INTERACTIVE_STATE_HAS_BACKENDS_CACHE=""
  INTERACTIVE_STATE_HAS_PORT_MAPPINGS_CACHE=""
  INTERACTIVE_STATE_HAS_CERTS_CACHE=""
  INTERACTIVE_STATE_HAS_BACKEND_HEADERS_CACHE=""
  INTERACTIVE_STATE_HAS_MTLS_BACKENDS_CACHE=""
  INTERACTIVE_STATE_HAS_ACL_RULES_CACHE=""
  INTERACTIVE_STATE_HAS_SECURITY_RULES_CACHE=""
  INTERACTIVE_STATE_HAS_BACKUPS_CACHE=""
}

function interactive_command_display_suffix_cache_begin() {
  INTERACTIVE_COMMAND_DISPLAY_SUFFIX_CACHE_ACTIVE=true
  _interactive_command_display_suffix_cache_reset
}

function interactive_command_display_suffix_cache_end() {
  INTERACTIVE_COMMAND_DISPLAY_SUFFIX_CACHE_ACTIVE=false
  _interactive_command_display_suffix_cache_reset
}

function _interactive_command_cached_check() {
  local cache_var="${1:-}" cached="" status=1
  shift || return 1

  if [ "${INTERACTIVE_COMMAND_DISPLAY_SUFFIX_CACHE_ACTIVE:-false}" = true ] && [ -n "$cache_var" ]; then
    cached="${!cache_var}"
    case "$cached" in
    0) return 0 ;;
    1) return 1 ;;
    esac
  fi

  if "$@"; then
    status=0
  else
    status=1
  fi

  if [ "${INTERACTIVE_COMMAND_DISPLAY_SUFFIX_CACHE_ACTIVE:-false}" = true ] && [ -n "$cache_var" ]; then
    printf -v "$cache_var" '%s' "$status"
  fi
  return "$status"
}

function _interactive_state_csv_has_rows() {
  local file="${1:-}" header="${2:-}" count=""
  [ -n "$file" ] || return 1
  [ -f "$file" ] || return 1
  count="$(csv_data_row_count "$file" "$header" 2>/dev/null)" || return 1
  [ "${count:-0}" -gt 0 ] 2>/dev/null
}

function _interactive_state_has_port_mappings() {
  local backend_ports_file="${BACKEND_PORTS_FILE:-}"
  [ -n "$backend_ports_file" ] || return 1
  [ -f "$backend_ports_file" ] || return 1
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "${STATE_BACKEND_PORTS_COLS:-0}" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] && return 0
  done <"$backend_ports_file"
  return 1
}

function _interactive_state_has_certs() {
  local provider cert_dir certs_dir="${CERTS_DIR:-}"
  [ -n "$certs_dir" ] || return 1
  for provider in letsencrypt selfsigned custom; do
    [ -d "${certs_dir}/${provider}/live" ] || continue
    for cert_dir in "${certs_dir}/${provider}/live"/*; do
      [ -d "$cert_dir" ] || continue
      return 0
    done
  done
  return 1
}

function _interactive_state_has_backend_headers() {
  _interactive_state_csv_has_rows "${BACKEND_HEADERS_FILE:-}" "${STATE_BACKEND_HEADERS_HEADER:-}"
}

function _interactive_state_has_mtls_backends() {
  _interactive_state_csv_has_rows "${BACKEND_MTLS_FILE:-}" "${STATE_BACKEND_MTLS_HEADER:-}"
}

function _interactive_state_has_acl_rules() {
  local rules_file="${SECURITY_IP_RULES_DB:-${SECURITY_IP_RULES_FILE:-}}"
  _interactive_state_csv_has_rows "$rules_file" "${STATE_SECURITY_IP_RULES_HEADER:-}"
}

function _interactive_state_has_security_rules() {
  local rules_file="${SECURITY_RULES_DB:-${SECURITY_RULES_FILE:-}}"
  _interactive_state_csv_has_rows "$rules_file" "${STATE_SECURITY_RULES_HEADER:-}"
}

function _interactive_state_has_backups() {
  local backups_dir="${BACKUP_DIR:-}" backup_item=""
  [ -n "$backups_dir" ] || return 1
  [ -d "$backups_dir" ] || return 1

  for backup_item in "$backups_dir"/*; do
    [ -e "$backup_item" ] || continue
    if [ -d "$backup_item" ]; then
      return 0
    fi
    case "$(basename "$backup_item")" in
    *.tar.gz)
      return 0
      ;;
    esac
  done

  return 1
}

function interactive_command_availability() {
  local cmd="${1:-}"
  INTERACTIVE_COMMAND_UNAVAILABLE_KIND=""
  INTERACTIVE_NO_STATE_ACTION=""

  if declare -F cmd_requires_existing_backend >/dev/null 2>&1 &&
    declare -F has_backends >/dev/null 2>&1 &&
    cmd_requires_existing_backend "$cmd" &&
    ! _interactive_command_cached_check INTERACTIVE_STATE_HAS_BACKENDS_CACHE has_backends; then
    INTERACTIVE_COMMAND_UNAVAILABLE_KIND="no_backends"
    return 1
  fi

  case "$cmd" in
  remove-port | update-port | enable-ws | disable-ws | set-port-redirect | remove-port-redirect | add-path-option | update-path-option | remove-path-option | remove-all-path-options | list-path-options | set-port-http3 | list-port-http3 | set-port-tls-protocols | set-port-tls-ciphers | remove-port-tls-protocols | remove-port-tls-ciphers)
    if ! _interactive_command_cached_check INTERACTIVE_STATE_HAS_PORT_MAPPINGS_CACHE _interactive_state_has_port_mappings; then
      INTERACTIVE_COMMAND_UNAVAILABLE_KIND="no_port_mappings"
      return 1
    fi
    ;;
  remove-cert)
    if ! _interactive_command_cached_check INTERACTIVE_STATE_HAS_CERTS_CACHE _interactive_state_has_certs; then
      INTERACTIVE_COMMAND_UNAVAILABLE_KIND="no_certs"
      return 1
    fi
    ;;
  restore-backup)
    if ! _interactive_command_cached_check INTERACTIVE_STATE_HAS_BACKUPS_CACHE _interactive_state_has_backups; then
      INTERACTIVE_COMMAND_UNAVAILABLE_KIND="no_backups"
      return 1
    fi
    ;;
  update-backend-header | remove-backend-header | remove-all-backend-headers | list-backend-headers)
    if ! _interactive_command_cached_check INTERACTIVE_STATE_HAS_BACKEND_HEADERS_CACHE _interactive_state_has_backend_headers; then
      INTERACTIVE_COMMAND_UNAVAILABLE_KIND="no_backend_headers"
      return 1
    fi
    ;;
  disable-backend-mtls | add-backend-client-cert | remove-backend-client-cert | list-backend-client-certs | replace-backend-client-cert | export-backend-client-p12 | list-backend-cas | replace-backend-ca | remove-backend-ca)
    if ! _interactive_command_cached_check INTERACTIVE_STATE_HAS_MTLS_BACKENDS_CACHE _interactive_state_has_mtls_backends; then
      INTERACTIVE_COMMAND_UNAVAILABLE_KIND="no_mtls"
      return 1
    fi
    ;;
  remove-acl | disable-acl | enable-acl | update-acl | move-acl-rule | remove-all-acl | disable-all-acl | enable-all-acl)
    if ! _interactive_command_cached_check INTERACTIVE_STATE_HAS_ACL_RULES_CACHE _interactive_state_has_acl_rules; then
      INTERACTIVE_COMMAND_UNAVAILABLE_KIND="no_acl_rules"
      return 1
    fi
    ;;
  remove-security-rule | disable-security-rule | enable-security-rule | update-security-rule | set-security-rule-mode | duplicate-security-rule | move-security-rule | remove-all-security-rules | disable-all-security-rules | enable-all-security-rules)
    if ! _interactive_command_cached_check INTERACTIVE_STATE_HAS_SECURITY_RULES_CACHE _interactive_state_has_security_rules; then
      INTERACTIVE_COMMAND_UNAVAILABLE_KIND="no_security_rules"
      return 1
    fi
    ;;
  esac

  return 0
}

function interactive_command_unavailable_label() {
  local kind="${1:-}"
  case "$kind" in
  no_backends) printf '%s' "no backends" ;;
  no_port_mappings) printf '%s' "no port mappings" ;;
  no_certs) printf '%s' "no certificates" ;;
  no_backups) printf '%s' "no local backups" ;;
  no_backend_headers) printf '%s' "no backend headers" ;;
  no_mtls) printf '%s' "no mTLS-enabled backends" ;;
  no_acl_rules) printf '%s' "no ACL rules" ;;
  no_security_rules) printf '%s' "no security rules" ;;
  *) printf '%s' "missing required state" ;;
  esac
}

function interactive_command_is_soft_unavailable() {
  local cmd="${1:-}" kind="${2:-${INTERACTIVE_COMMAND_UNAVAILABLE_KIND:-}}"
  [ "$cmd" = "restore-backup" ] && [ "$kind" = "no_backups" ]
}

function interactive_command_display_suffix() {
  local cmd="${1:-}" __out_var="${2:-}" kind="" label="" suffix_text=""
  if [ -n "$__out_var" ]; then
    printf -v "$__out_var" '%s' ""
  fi
  [ -n "$cmd" ] || return 0

  if interactive_command_availability "$cmd"; then
    return 0
  fi

  kind="${INTERACTIVE_COMMAND_UNAVAILABLE_KIND:-}"
  if interactive_command_is_soft_unavailable "$cmd" "$kind"; then
    suffix_text="no local backups; manual path allowed"
    if [ -n "$__out_var" ]; then
      printf -v "$__out_var" '%s' "$suffix_text"
    else
      printf '%s' "$suffix_text"
    fi
    return 0
  fi

  label="$(interactive_command_unavailable_label "$kind")"
  suffix_text="unavailable: ${label}"
  if [ -n "$__out_var" ]; then
    printf -v "$__out_var" '%s' "$suffix_text"
  else
    printf '%s' "$suffix_text"
  fi
}

function interactive_no_state_guidance() {
  local cmd="${1:-}" kind="${INTERACTIVE_COMMAND_UNAVAILABLE_KIND:-}" prompt="" action="" action_label="" idx choose_status=0
  INTERACTIVE_NO_STATE_ACTION=""

  case "$kind" in
  no_backends)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs an existing backend, but no backends are configured."$'\n\n'"Suggested next action:"
    action="add-backend"
    action_label="Add backend now"
    ;;
  no_port_mappings)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs an existing port mapping, but no port mappings are configured."$'\n\n'"Suggested next action:"
    action="add-port"
    action_label="Add port now"
    ;;
  no_certs)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs an existing certificate, but no certificates are configured."$'\n\n'"Suggested next action:"
    action="add-cert"
    action_label="Add certificate now"
    ;;
  no_backups)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs an existing backup, but no backups are available."$'\n\n'"Suggested next action:"
    action="create-backup"
    action_label="Create backup now"
    ;;
  no_backend_headers)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs backend header state, but no backend headers are configured."$'\n\n'"Suggested next action:"
    action="add-backend-header"
    action_label="Add backend header now"
    ;;
  no_mtls)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs an mTLS-enabled backend, but none are configured."$'\n\n'"Suggested next action:"
    action="enable-backend-mtls"
    action_label="Enable backend mTLS now"
    ;;
  no_acl_rules)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs an existing ACL rule, but no ACL rules are configured."$'\n\n'"Suggested next action:"
    action="add-acl"
    action_label="Add ACL rule now"
    ;;
  no_security_rules)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs an existing security rule, but no security rules are configured."$'\n\n'"Suggested next action:"
    action="add-security-rule"
    action_label="Add security rule now"
    ;;
  *)
    prompt="=== Missing setup ==="$'\n'"$(command_alias "$cmd") needs state that is not configured yet."$'\n\n'"Suggested next action:"
    action=""
    action_label="Return to previous menu"
    ;;
  esac

  if [ -n "$action" ]; then
    if [ "$kind" = "no_backups" ] && [ "$cmd" = "restore-backup" ]; then
      choose_option_with_context_status choose_status idx "no-state-guidance" "$prompt" "$action_label" "Enter backup path manually" "Return to previous menu" "Quit"
      if [ "$choose_status" -ne 0 ]; then
        return 1
      fi
      case "$idx" in
      0)
        INTERACTIVE_NO_STATE_ACTION="$action"
        return 0
        ;;
      1)
        return 3
        ;;
      2)
        return 1
        ;;
      *)
        return 2
        ;;
      esac
    fi

    choose_option_with_context_status choose_status idx "no-state-guidance" "$prompt" "$action_label" "Return to previous menu" "Quit"
    if [ "$choose_status" -ne 0 ]; then
      return 1
    fi
    case "$idx" in
    0)
      INTERACTIVE_NO_STATE_ACTION="$action"
      return 0
      ;;
    1)
      return 1
      ;;
    *)
      return 2
      ;;
    esac
  fi

  choose_option_with_context_status choose_status idx "no-state-guidance" "$prompt" "Return to previous menu" "Quit"
  if [ "$choose_status" -ne 0 ]; then
    return 1
  fi
  [ "$idx" -eq 1 ] 2>/dev/null && return 2
  return 1
}
