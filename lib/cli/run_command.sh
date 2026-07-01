# shellcheck shell=bash

function _run_command_audit_message() {
  local cmd="$1"
  shift || true
  local args=("$@")
  local spec="" idx=0 arg="" arg_name="" consume_next_option_value=false consume_next_option_arg_name="" positional_idx=0
  local next_arg="" sensitive_value=false option_idx=0 consume_next_option_spec_idx=0

  printf '%s' "$cmd"
  if declare -F get_arg_spec >/dev/null 2>&1 &&
    declare -F cli_parse_arg_spec >/dev/null 2>&1; then
    spec="$(get_arg_spec "$cmd" 2>/dev/null || true)"
    cli_parse_arg_spec "$spec"
  else
    CLI_SPEC_NAMES=()
  fi

  [ "${#args[@]}" -gt 0 ] 2>/dev/null || return 0

  for idx in "${!args[@]}"; do
    arg="${args[$idx]}"
    if [ "$consume_next_option_value" = true ]; then
      next_arg=""
      if [ "$idx" -lt "$((${#args[@]} - 1))" ]; then
        next_arg="${args[$((idx + 1))]}"
      fi
      sensitive_value=false
      if [ -n "$consume_next_option_arg_name" ] &&
        _run_command_arg_is_sensitive "$cmd" "$consume_next_option_arg_name" "$arg"; then
        sensitive_value=true
        printf ' %s' "$OPERATOR_VISIBILITY_REDACTED_VALUE"
      elif _run_command_should_redact_sensitive_trailing_words "$cmd" "$consume_next_option_arg_name" "$next_arg"; then
        printf ' %s' "$OPERATOR_VISIBILITY_REDACTED_VALUE"
        break
      else
        printf ' %s' "$arg"
      fi
      if [ "$sensitive_value" = true ] &&
        _run_command_should_stop_after_redacted_value "$cmd" "$consume_next_option_arg_name" "$arg" "$next_arg"; then
        break
      fi
      if [ "$positional_idx" -le "$consume_next_option_spec_idx" ] 2>/dev/null; then
        positional_idx=$((consume_next_option_spec_idx + 1))
      fi
      consume_next_option_value=false
      consume_next_option_arg_name=""
      consume_next_option_spec_idx=0
      continue
    fi
    if [[ "$arg" == --*=* ]] && _run_command_arg_name_for_option arg_name "${arg%%=*}"; then
      next_arg=""
      if [ "$idx" -lt "$((${#args[@]} - 1))" ]; then
        next_arg="${args[$((idx + 1))]}"
      fi
      if _run_command_arg_is_sensitive "$cmd" "$arg_name" "${arg#*=}"; then
        printf ' %s=%s' "${arg%%=*}" "$OPERATOR_VISIBILITY_REDACTED_VALUE"
        if _run_command_should_stop_after_redacted_value "$cmd" "$arg_name" "${arg#*=}" "$next_arg"; then
          break
        fi
      elif _run_command_should_redact_sensitive_trailing_words "$cmd" "$arg_name" "$next_arg"; then
        printf ' %s=%s' "${arg%%=*}" "$OPERATOR_VISIBILITY_REDACTED_VALUE"
        break
      else
        printf ' %s' "$arg"
      fi
      if _run_command_arg_index_for_name option_idx "$arg_name" &&
        [ "$positional_idx" -le "$option_idx" ] 2>/dev/null; then
        positional_idx=$((option_idx + 1))
      fi
      continue
    fi
    if _run_command_arg_name_for_option arg_name "$arg"; then
      printf ' %s' "$arg"
      consume_next_option_value=true
      consume_next_option_arg_name="$arg_name"
      consume_next_option_spec_idx=0
      _run_command_arg_index_for_name consume_next_option_spec_idx "$arg_name" || true
      continue
    fi
    arg_name=""
    if [ "$positional_idx" -lt "${#CLI_SPEC_NAMES[@]}" ] 2>/dev/null; then
      arg_name="${CLI_SPEC_NAMES[$positional_idx]}"
    fi
    if [[ "$arg" == --* ]] && [ -n "$arg_name" ] &&
      ! _run_command_arg_is_sensitive "$cmd" "$arg_name" "$arg"; then
      printf ' %s' "$arg"
      continue
    fi
    if [ -n "$arg_name" ] && _run_command_arg_is_sensitive "$cmd" "$arg_name" "$arg"; then
      printf ' %s' "$OPERATOR_VISIBILITY_REDACTED_VALUE"
      if _run_command_sensitive_arg_consumes_remainder "$cmd" "$arg_name" ||
        _run_command_sensitive_arg_redacts_trailing_words "$cmd" "$arg_name"; then
        break
      fi
    elif _run_command_should_redact_sensitive_remainder "$cmd" "$arg_name" "$idx" "${#args[@]}"; then
      printf ' %s' "$OPERATOR_VISIBILITY_REDACTED_VALUE"
      break
    else
      printf ' %s' "$arg"
    fi
    positional_idx=$((positional_idx + 1))
  done
}

function _run_command_sensitive_arg_consumes_remainder() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  set-nginx-docker-opts:docker_opts)
    return 0
    ;;
  esac
  return 1
}

function _run_command_sensitive_arg_redacts_trailing_words() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  add-header:value | update-header:value \
  | add-backend-header:value | update-backend-header:value \
  | set-hsts:hsts_value | set-backend-hsts:backend_hsts_value \
  | set-csp:csp_value | set-backend-csp:backend_csp_value)
    return 0
    ;;
  esac
  return 1
}

function _run_command_should_redact_sensitive_remainder() {
  local cmd="${1:-}" arg_name="${2:-}" idx="${3:-0}" arg_count="${4:-0}"
  [ -n "$arg_name" ] || return 1
  _run_command_arg_is_sensitive "$cmd" "$arg_name" || return 1
  _run_command_sensitive_arg_consumes_remainder "$cmd" "$arg_name" || return 1
  [ "$idx" -lt "$((arg_count - 1))" ] 2>/dev/null
}

function _run_command_is_redaction_boundary_option() {
  local cmd="${1:-}" option="${2:-}"
  case "${cmd}:${option}" in
  add-backend:--no-expose)
    return 0
    ;;
  esac
  return 1
}

function _run_command_next_arg_is_cli_option() {
  local cmd="${1:-}" next_arg="${2:-}" option="" arg_name=""
  [ -n "$next_arg" ] || return 1
  option="$next_arg"
  if [[ "$next_arg" == --*=* ]]; then
    option="${next_arg%%=*}"
  fi
  _run_command_is_redaction_boundary_option "$cmd" "$option" && return 0
  _run_command_arg_name_for_option arg_name "$option"
}

function _run_command_should_redact_sensitive_trailing_words() {
  local cmd="${1:-}" arg_name="${2:-}" next_arg="${3:-}"
  [ -n "$arg_name" ] || return 1
  [ -n "$next_arg" ] || return 1
  _run_command_arg_is_sensitive "$cmd" "$arg_name" || return 1
  if _run_command_sensitive_arg_redacts_trailing_words "$cmd" "$arg_name" ||
    [ "$arg_name" = "docker_opts" ]; then
    ! _run_command_next_arg_is_cli_option "$cmd" "$next_arg"
    return
  fi
  return 1
}

function _run_command_should_stop_after_redacted_value() {
  local cmd="${1:-}" arg_name="${2:-}" value="${3:-}" next_arg="${4:-}"
  _run_command_sensitive_arg_consumes_remainder "$cmd" "$arg_name" && return 0
  _run_command_sensitive_arg_redacts_trailing_words "$cmd" "$arg_name" && return 0
  if [ "$arg_name" = "docker_opts" ] && [[ "$value" == --* ]] &&
    [ -n "$next_arg" ] && ! _run_command_next_arg_is_cli_option "$cmd" "$next_arg"; then
    return 0
  fi
  return 1
}

function _run_command_arg_is_sensitive() {
  declare -F arg_is_sensitive >/dev/null 2>&1 || return 1
  arg_is_sensitive "$@"
}

function _run_command_has_sensitive_args() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  local spec="" idx=0 arg="" arg_name="" positional_idx=0 consume_next_option_value=false consume_next_option_arg_name=""
  local next_arg="" option_idx=0 consume_next_option_spec_idx=0

  declare -F get_arg_spec >/dev/null 2>&1 || return 1
  declare -F cli_parse_arg_spec >/dev/null 2>&1 || return 1
  declare -F arg_is_sensitive >/dev/null 2>&1 || return 1

  spec="$(get_arg_spec "$cmd" 2>/dev/null || true)"
  cli_parse_arg_spec "$spec"

  [ "${#args[@]}" -gt 0 ] 2>/dev/null || return 1

  for idx in "${!args[@]}"; do
    arg="${args[$idx]}"
    if [ "$consume_next_option_value" = true ]; then
      next_arg=""
      if [ "$idx" -lt "$((${#args[@]} - 1))" ]; then
        next_arg="${args[$((idx + 1))]}"
      fi
      if [ -n "$consume_next_option_arg_name" ] &&
        _run_command_arg_is_sensitive "$cmd" "$consume_next_option_arg_name" "$arg"; then
        return 0
      fi
      if _run_command_should_redact_sensitive_trailing_words "$cmd" "$consume_next_option_arg_name" "$next_arg"; then
        return 0
      fi
      if [ "$positional_idx" -le "$consume_next_option_spec_idx" ] 2>/dev/null; then
        positional_idx=$((consume_next_option_spec_idx + 1))
      fi
      consume_next_option_value=false
      consume_next_option_arg_name=""
      consume_next_option_spec_idx=0
      continue
    fi
    if [[ "$arg" == --*=* ]] && _run_command_arg_name_for_option arg_name "${arg%%=*}"; then
      next_arg=""
      if [ "$idx" -lt "$((${#args[@]} - 1))" ]; then
        next_arg="${args[$((idx + 1))]}"
      fi
      if _run_command_arg_is_sensitive "$cmd" "$arg_name" "${arg#*=}"; then
        return 0
      fi
      if _run_command_should_redact_sensitive_trailing_words "$cmd" "$arg_name" "$next_arg"; then
        return 0
      fi
      if _run_command_arg_index_for_name option_idx "$arg_name" &&
        [ "$positional_idx" -le "$option_idx" ] 2>/dev/null; then
        positional_idx=$((option_idx + 1))
      fi
      continue
    fi
    if _run_command_arg_name_for_option arg_name "$arg"; then
      consume_next_option_value=true
      consume_next_option_arg_name="$arg_name"
      consume_next_option_spec_idx=0
      _run_command_arg_index_for_name consume_next_option_spec_idx "$arg_name" || true
      continue
    fi
    arg_name=""
    if [ "$positional_idx" -lt "${#CLI_SPEC_NAMES[@]}" ] 2>/dev/null; then
      arg_name="${CLI_SPEC_NAMES[$positional_idx]}"
    fi
    if [[ "$arg" == --* ]] && [ -n "$arg_name" ] &&
      ! _run_command_arg_is_sensitive "$cmd" "$arg_name" "$arg"; then
      continue
    fi
    if [ -n "$arg_name" ] && _run_command_arg_is_sensitive "$cmd" "$arg_name" "$arg"; then
      return 0
    fi
    if _run_command_should_redact_sensitive_remainder "$cmd" "$arg_name" "$idx" "${#args[@]}"; then
      return 0
    fi
    positional_idx=$((positional_idx + 1))
  done

  return 1
}

function _run_command_arg_index_for_name() {
  local __arg_idx_var="${1:-}" target_name="${2:-}"
  local spec_idx=0

  require_valid_var_name "$__arg_idx_var" || return 1
  [ -n "$target_name" ] || return 1
  [ "${#CLI_SPEC_NAMES[@]}" -gt 0 ] 2>/dev/null || return 1

  for spec_idx in "${!CLI_SPEC_NAMES[@]}"; do
    if [ "${CLI_SPEC_NAMES[$spec_idx]}" = "$target_name" ]; then
      printf -v "$__arg_idx_var" '%s' "$spec_idx"
      return 0
    fi
  done

  return 1
}

function _run_command_arg_name_for_option() {
  local __arg_name_var="${1:-}" option="${2:-}"
  local normalized spec_arg_name

  require_valid_var_name "$__arg_name_var" || return 1
  case "$option" in
  --*) normalized="${option#--}" ;;
  *) return 1 ;;
  esac
  normalized="${normalized//-/_}"

  [ "${#CLI_SPEC_NAMES[@]}" -gt 0 ] 2>/dev/null || return 1

  for spec_arg_name in "${CLI_SPEC_NAMES[@]}"; do
    if [ "$spec_arg_name" = "$normalized" ]; then
      printf -v "$__arg_name_var" '%s' "$spec_arg_name"
      return 0
    fi
  done

  return 1
}

function _run_command_verbose_message() {
  local cmd="$1"
  shift || true
  if declare -F operator_visibility_is_redacted >/dev/null 2>&1 &&
    operator_visibility_is_redacted; then
    _run_command_audit_message "$cmd" "$@"
    return 0
  fi

  printf '%s' "$cmd"
  for arg in "$@"; do
    printf ' %s' "$arg"
  done
}

function run_command() {
  local CMD="$1"
  shift || true

  if ! declare -F dockistrate_command_skips_runtime_prep >/dev/null 2>&1 ||
    ! dockistrate_command_skips_runtime_prep "$CMD" "$@"; then
    audit_log "$(_run_command_audit_message "$CMD" "$@")"
  fi

  if [ "${VERBOSE:-false}" = true ]; then
    printf '[Verbose] run_command %s\n' "$(_run_command_verbose_message "$CMD" "$@")" >&2
  fi

  case "$CMD" in
  help) help_command "$@" ;;
  help-update) help_update ;;
  upgrade-preflight) upgrade_preflight "$@" ;;
  start-nginx) start_nginx "$@" ;;
  stop-nginx) stop_nginx ;;
  remove-nginx) remove_nginx ;;
  status) status ;;
  status-all) status_all ;;
  list-backends) list_backends ;;
  fix-default-config) fix_default_config ;;
  update-nginx-config) update_nginx_config ;;
  add-backend) add_backend "$@" ;;
  remove-backend) remove_backend "$@" ;;
  add-host-alias) add_host_alias "$@" ;;
  remove-host-alias) remove_host_alias "$@" ;;
  list-host-aliases) list_host_aliases "$@" ;;
  add-dedicated-host) add_dedicated_host "$@" ;;
  remove-dedicated-host) remove_dedicated_host "$@" ;;
  list-dedicated-hosts) list_dedicated_hosts "$@" ;;
  set-dedicated-host-inherit) set_dedicated_host_inherit "$@" ;;
  show-dedicated-host-inherit) show_dedicated_host_inherit "$@" ;;
  start-backend) start_backend "$@" ;;
  stop-backend) stop_backend "$@" ;;
  restart-backend) restart_backend "$@" ;;
  update-backend) update_backend "$@" ;;
  replace-backend-network) replace_backend_network "$@" ;;
  # legacy TCP commands removed in unified mode
  start-all-backends) start_all_backends ;;
  stop-all-backends) stop_all_backends ;;
  restart-all-backends) restart_all_backends ;;
  remove-all-backends) remove_all_backends ;;
  add-cert) add_cert "$@" ;;
  replace-cert) replace_cert "$@" ;;
  list-certs) list_certs ;;
  renew-certs) renew_certs ;;
  remove-cert) remove_cert "$@" ;;
  add-port) add_port_mapping "$@" ;;
  remove-port) remove_port_mapping "$@" ;;
  update-port) update_port_mapping "$@" ;;
  set-port-redirect) set_port_redirect "$@" ;;
  remove-port-redirect) remove_port_redirect "$@" ;;
  add-path-option) add_path_option "$@" ;;
  update-path-option) update_path_option "$@" ;;
  remove-path-option) remove_path_option "$@" ;;
  remove-all-path-options) remove_all_path_options "$@" ;;
  list-path-options) list_path_options "$@" ;;
  list-port-mappings) list_port_mappings ;;
  # legacy dedicated TCP port commands removed in unified mode
  enable-ws) enable_ws "$@" ;;
  disable-ws) disable_ws "$@" ;;
  clean-all) clean_all "$@" ;;
  uninstall-all) uninstall_all "$@" ;;
  set-nginx-directive) set_nginx_directive "$@" ;;
  set-nginx-directive-raw) set_nginx_directive_raw "$@" ;;
  remove-nginx-directive) remove_nginx_directive "$@" ;;
  remove-all-nginx-directives) remove_all_nginx_directives "$@" ;;
  list-nginx-directives) list_nginx_directives "$@" ;;
  list-nginx-directive-catalog) list_nginx_directive_catalog ;;
  set-nginx-directive-strict) set_nginx_directive_strict "$@" ;;
  show-nginx-directive-strict) show_nginx_directive_strict ;;
  control-server-tokens) control_server_tokens "$@" ;;
  show-server-tokens) show_server_tokens ;;
  set-client-ip-header) set_client_ip_header "$@" ;;
  set-backend-client-ip-header) set_backend_client_ip_header "$@" ;;
  remove-backend-client-ip-header) remove_backend_client_ip_header "$@" ;;
  set-proxy-ip-header) set_proxy_ip_header "$@" ;;
  set-backend-proxy-ip-header) set_backend_proxy_ip_header "$@" ;;
  remove-backend-proxy-ip-header) remove_backend_proxy_ip_header "$@" ;;
  add-header) set_header "$@" ;;
  update-header) set_header "$@" ;;
  remove-header) remove_header "$@" ;;
  list-headers) list_headers ;;
  remove-all-headers) remove_all_headers ;;
  add-backend-header) set_backend_header "$@" ;;
  update-backend-header) set_backend_header "$@" ;;
  remove-backend-header) remove_backend_header "$@" ;;
  remove-all-backend-headers) remove_all_backend_headers "$@" ;;
  list-backend-headers) list_backend_headers "$@" ;;
  set-hsts) set_hsts "$@" ;;
  set-backend-hsts) set_backend_hsts "$@" ;;
  set-csp) set_csp "$@" ;;
  set-backend-csp) set_backend_csp "$@" ;;
  list-log-fields) list_log_fields ;;
  add-log-field) add_log_field "$@" ;;
  remove-log-field) remove_log_field "$@" ;;
  update-log-field) update_log_field "$@" ;;
  move-log-field) move_log_field "$@" ;;
  set-backend-http-version) set_backend_http_version "$@" ;;
  remove-backend-http-version) remove_backend_http_version "$@" ;;
  set-port-tls-protocols) set_port_tls_protocols "$@" ;;
  remove-port-tls-protocols) remove_port_tls_protocols "$@" ;;
  set-port-tls-ciphers) set_port_tls_ciphers "$@" ;;
  remove-port-tls-ciphers) remove_port_tls_ciphers "$@" ;;
  set-port-http3) set_port_http3 "$@" ;;
  list-port-http3) list_port_http3 "$@" ;;
  enable-backend-mtls) enable_backend_mtls "$@" ;;
  disable-backend-mtls) disable_backend_mtls "$@" ;;
  add-backend-client-cert) add_backend_client_cert "$@" ;;
  revoke-backend-client-cert) revoke_backend_client_cert "$@" ;;
  remove-backend-client-cert) remove_backend_client_cert "$@" ;;
  list-backend-client-certs) list_backend_client_certs "$@" ;;
  replace-backend-client-cert) replace_backend_client_cert "$@" ;;
  export-backend-client-p12) export_backend_client_p12 "$@" ;;
  list-backend-cas) list_backend_cas ;;
  replace-backend-ca) replace_backend_ca "$@" ;;
  remove-backend-ca) remove_backend_ca "$@" ;;
  set-backend-acl-policy) set_backend_acl_policy "$@" ;;
  remove-backend-acl-policy) remove_backend_acl_policy "$@" ;;
  # unified ACL: no separate L3 policy commands
  set-backend-acl-status) set_backend_acl_status "$@" ;;
  remove-backend-acl-status) remove_backend_acl_status "$@" ;;
  set-backend-security-rule-status) set_backend_security_rule_status "$@" ;;
  remove-backend-security-rule-status) remove_backend_security_rule_status "$@" ;;
  # ACL (unified) aliases to security-ip engine
  add-acl) add_security_ip "$@" ;;
  remove-acl) remove_security_ip "$@" ;;
  disable-acl) disable_security_ip_rule "$@" ;;
  enable-acl) enable_security_ip_rule "$@" ;;
  remove-all-acl) remove_all_security_ip_rules ;;
  disable-all-acl) disable_all_security_ip_rules ;;
  enable-all-acl) enable_all_security_ip_rules ;;
  update-acl) update_security_ip "$@" ;;
  move-acl-rule) move_security_ip_rule "$@" ;;
  list-acl) list_security_ip ;;
  # legacy operator-specific commands removed
  add-security-rule) add_security_rule "$@" ;;
  fix-permissions) fix_permissions_cmd "$@" ;;
  remove-security-rule) remove_security_rule "$@" ;;
  remove-all-security-rules) remove_all_security_rules ;;
  disable-security-rule) disable_security_rule "$@" ;;
  enable-security-rule) enable_security_rule "$@" ;;
  disable-all-security-rules) disable_all_security_rules ;;
  enable-all-security-rules) enable_all_security_rules ;;
  update-security-rule) update_security_rule "$@" ;;
  set-security-rule-mode) set_security_rule_mode "$@" ;;
  # legacy operator-specific commands removed
  move-security-rule) move_security_rule "$@" ;;
  list-security-rules) list_security_rules "$@" ;;
  duplicate-security-rule) duplicate_security_rule "$@" ;;
  check-config) check_config ;;
  tail-proxy-logs) tail_proxy_logs "$@" ;;
  create-backup) create_backup_cmd "$@" ;;
  list-backups) list_backups ;;
  restore-backup) restore_backup "$@" ;;
  set-auto-backups) set_auto_backups "$@" ;;
  set-backup-retention) set_backup_retention "$@" ;;
  set-backup-compression) set_backup_compression "$@" ;;
  set-http-version) set_http_version "$@" ;;
  set-tls-protocols) set_tls_protocols "$@" ;;
  set-tls-ciphers) set_tls_ciphers "$@" ;;
  set-security-rule-status) set_security_rule_status "$@" ;;
  set-acl-status) set_acl_status "$@" ;;
  set-acl-policy) set_acl_policy "$@" ;;
  # unified ACL: no separate set-l3-acl-policy command
  set-trusted-proxies) set_trusted_proxies "$@" ;;
  set-real-ip-recursive) set_real_ip_recursive "$@" ;;
  set-nginx-docker-opts) set_nginx_docker_opts "$@" ;;
  show-nginx-docker-opts) show_nginx_docker_opts ;;
  set-visibility-policy) set_visibility_policy "$@" ;;
  show-visibility-policy) show_visibility_policy ;;
  set-nginx-image) set_nginx_image "$@" ;;
  set-certbot-image) set_certbot_image "$@" ;;
  start-capture) start_capture "$@" ;;
  stop-capture) stop_capture ;;
  *)
    usage
    return 1
    ;;
  esac
}
