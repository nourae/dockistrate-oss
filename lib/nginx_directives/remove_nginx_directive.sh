# shellcheck shell=bash

function remove_nginx_directive() {
  local scope_input="${1:-}" scope="" domain="" listen_port="" path_prefix="" directive="" removed_count="0"
  local usage_msg="[Usage] remove-nginx-directive <global|backend|port|path|stream-global|stream-backend|stream-port> [domain] [listen_port] [path_prefix] <directive>"

  if [ -z "$scope_input" ]; then
    echo "$usage_msg"
    return 1
  fi

  scope="$(nginx_directive_normalize_scope "$scope_input" 2>/dev/null || true)"
  if [ -z "$scope" ]; then
    echo "$usage_msg"
    return 1
  fi

  case "$scope" in
  "$NGINX_DIRECTIVE_SCOPE_GLOBAL" | "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL")
    directive="${2:-}"
    ;;
  "$NGINX_DIRECTIVE_SCOPE_BACKEND" | "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND")
    domain="${2:-}"
    directive="${3:-}"
    ;;
  "$NGINX_DIRECTIVE_SCOPE_PORT" | "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT")
    domain="${2:-}"
    listen_port="${3:-}"
    directive="${4:-}"
    ;;
  "$NGINX_DIRECTIVE_SCOPE_PATH")
    domain="${2:-}"
    listen_port="${3:-}"
    path_prefix="${4:-}"
    directive="${5:-}"
    ;;
  esac

  if [ -z "$directive" ]; then
    echo "$usage_msg"
    return 1
  fi

  if ! nginx_directives_resolve_scope_target scope domain listen_port path_prefix "$scope" "$domain" "$listen_port" "$path_prefix" "cleanup"; then
    return 1
  fi

  if ! nginx_directive_validate_name_token "$directive"; then
    echo "[Error] Invalid directive token: ${directive}" >&2
    return 1
  fi

  if ! nginx_directives_require_generic_remove_allowed "$directive"; then
    return 1
  fi

  begin_transaction "remove_nginx_directive_${scope}_${directive}" "$CONFIG_DIR"
  if ! removed_count="$(nginx_directives_state_remove_matching "$scope" "$domain" "$listen_port" "$path_prefix" "$directive")"; then
    _rollback_handler
  fi
  if ! update_nginx_config; then
    _rollback_handler
  fi
  end_transaction_success

  if [ "$removed_count" -gt 0 ]; then
    echo "[Info] Removed nginx directive '${directive}' (${removed_count} row(s))."
  else
    echo "[Info] No matching nginx directive '${directive}' found for requested scope."
  fi
}
