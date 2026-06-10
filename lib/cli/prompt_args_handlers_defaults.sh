# shellcheck shell=bash

# Compute default values for prompt_args_for_command
# Uses PROMPT_ARGS_CONTEXT array for args collected so far.
function prompt_args_compute_default() {
  local cmd="$1" name="$2" default="$3"

  if [[ "$cmd" == "update-backend" && "$name" == "image" ]]; then
    default="$(get_backend_image "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "update-backend" && "$name" == "container_port" ]]; then
    default="$(get_backend_port "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "update-backend" && "$name" == "network" ]]; then
    default="$(get_backend_network "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "update-backend" && "$name" == "docker_opts" ]]; then
    default="$(get_backend_docker_opts "backend:${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "start-nginx" && "$name" == "nginx_image" ]]; then
    default="$NGINX_IMAGE"
  fi
  if [[ "$cmd" == "start-nginx" && "$name" == "docker_opts" ]]; then
    default="$NGINX_DOCKER_OPTS"
  fi
  if [[ "$cmd" == "set-nginx-docker-opts" && "$name" == "docker_opts" ]]; then
    default="$NGINX_DOCKER_OPTS"
  fi

  # Header update defaults
  if [[ "$cmd" == "update-header" && "$name" == "value" ]]; then
    if [ -f "$CUSTOM_HEADERS_FILE" ] && [ -n "${PROMPT_ARGS_CONTEXT[0]:-}" ] && [ -n "${PROMPT_ARGS_CONTEXT[1]:-}" ]; then
      local line="" line_no=0
      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        csv_parse_line "$line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_CUSTOM_HEADERS_COLS" ] || continue
        if [ "${CSV_FIELDS[0]}" = "${PROMPT_ARGS_CONTEXT[0]}" ] && [ "${CSV_FIELDS[1]}" = "${PROMPT_ARGS_CONTEXT[1]}" ]; then
          default="${CSV_FIELDS[2]}"
          break
        fi
      done <"$CUSTOM_HEADERS_FILE"
    fi
  fi
  if [[ "$cmd" == "update-backend-header" && "$name" == "value" ]]; then
    if [ -f "$BACKEND_HEADERS_FILE" ] && [ -n "${PROMPT_ARGS_CONTEXT[0]:-}" ] && [ -n "${PROMPT_ARGS_CONTEXT[1]:-}" ] && [ -n "${PROMPT_ARGS_CONTEXT[2]:-}" ]; then
      local line="" line_no=0
      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        csv_parse_line "$line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_HEADERS_COLS" ] || continue
        if [ "${CSV_FIELDS[0]}" = "${PROMPT_ARGS_CONTEXT[0]}" ] && [ "${CSV_FIELDS[1]}" = "${PROMPT_ARGS_CONTEXT[1]}" ] && [ "${CSV_FIELDS[2]}" = "${PROMPT_ARGS_CONTEXT[2]}" ]; then
          default="${CSV_FIELDS[3]}"
          break
        fi
      done <"$BACKEND_HEADERS_FILE"
    fi
  fi

  # Per-backend header defaults
  if [[ "$cmd" == "set-backend-client-ip-header" && "$name" == "header_or_off" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    default="$(get_backend_client_ip_header "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "set-backend-proxy-ip-header" && "$name" == "header_or_off" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    default="$(get_backend_proxy_ip_header "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "set-backend-http-version" && "$name" == "version" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    default="$(get_backend_http_version "${PROMPT_ARGS_CONTEXT[0]}")"
  fi

  # Per-port TLS override defaults
  if [[ "$cmd" == "set-port-tls-protocols" && "$name" == "protocols" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    default="$(get_port_tls_protocols "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "set-port-tls-ciphers" && "$name" == "ciphers" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    default="$(get_port_tls_ciphers "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "set-backend-acl-policy" && "$name" == "policy" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    default="$(get_backend_acl_policy "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "set-backend-acl-status" && "$name" == "code" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    default="$(get_backend_acl_status "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "set-backend-security-rule-status" && "$name" == "code" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    default="$(get_backend_security_rule_status "${PROMPT_ARGS_CONTEXT[0]}")"
  fi
  if [[ "$cmd" == "set-acl-policy" && "$name" == "policy" ]]; then
    default="${ACL_POLICY:-$default}"
  fi
  if [[ "$cmd" == "set-acl-status" && "$name" == "code" ]]; then
    default="${ACL_STATUS:-$default}"
  fi
  if [[ "$cmd" == "set-security-rule-status" && "$name" == "code" ]]; then
    default="${SECURITY_RULE_STATUS:-$default}"
  fi

  # Port redirect defaults
  if [[ "$cmd" == "set-port-redirect" && ("$name" == "on_off" || "$name" == "code") ]]; then
    if [ -n "${PROMPT_ARGS_CONTEXT[0]:-}" ] && [ -n "${PROMPT_ARGS_CONTEXT[1]:-}" ] && [ -f "$BACKEND_PORTS_FILE" ]; then
      local _line="" _line_no=0 _redir="" _code=""
      while IFS= read -r _line || [ -n "$_line" ]; do
        _line_no=$((_line_no + 1))
        [ "$_line_no" -eq 1 ] && continue
        if ! state_backend_ports_parse_line "$_line"; then
          continue
        fi
        if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
          [ "$STATE_BP_DOMAIN" = "${PROMPT_ARGS_CONTEXT[0]}" ] &&
          [ "$STATE_BP_LISTEN_PORT" = "${PROMPT_ARGS_CONTEXT[1]}" ]; then
          _redir="$STATE_BP_REDIRECT_FLAG"
          _code="$STATE_BP_REDIRECT_CODE"
          break
        fi
      done <"$BACKEND_PORTS_FILE"
      if [ "$name" = "on_off" ]; then default="${_redir:-off}"; else default="${_code:-301}"; fi
    fi
  fi

  if [[ "$cmd" == "set-port-http3" && ("$name" == "http3" || "$name" == "alt_svc") ]]; then
    if [ -n "${PROMPT_ARGS_CONTEXT[0]:-}" ] && declare -F get_port_http3_state >/dev/null 2>&1; then
      local current_http3="" current_alt_svc=""
      if get_port_http3_state "${PROMPT_ARGS_CONTEXT[0]}" current_http3 current_alt_svc; then
        if [ "$name" = "http3" ]; then
          default="${current_http3:-off}"
        else
          default="${current_alt_svc:-auto}"
        fi
      fi
    fi
  fi

  # Server tokens default
  if [[ "$cmd" == "control-server-tokens" && "$name" == "on_off" ]]; then
    default="$(show_server_tokens 2>/dev/null || echo off)"
  fi

  # Logging — default field value by ID
  if [[ "$cmd" == "update-log-field" && "$name" == "field" && -n "${PROMPT_ARGS_CONTEXT[0]:-}" ]]; then
    if [[ "${PROMPT_ARGS_CONTEXT[0]}" =~ ^[0-9]+$ ]] && [ -f "$ACCESS_LOG_FIELDS_FILE" ]; then
      local target_id="${PROMPT_ARGS_CONTEXT[0]}"
      local row_no=0 line="" line_no=0
      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        csv_parse_line "$line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_ACCESS_LOG_FIELDS_COLS" ] || continue
        row_no=$((row_no + 1))
        if [ "$row_no" -eq "$target_id" ]; then
          default="${CSV_FIELDS[0]}"
          break
        fi
      done <"$ACCESS_LOG_FIELDS_FILE"
    fi
  fi

  printf '%s' "$default"
}
