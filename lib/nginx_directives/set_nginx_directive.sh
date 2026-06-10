# shellcheck shell=bash

function set_nginx_directive() {
  local scope_input="${1:-}" scope="" domain="" listen_port="" path_prefix="" directive="" value=""
  local usage_msg="[Usage] set-nginx-directive <global|backend|port|path|stream-global|stream-backend|stream-port> [domain] [listen_port] [path_prefix] <directive> <value>"

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
    shift 2 || true
    value="$*"
    ;;
  "$NGINX_DIRECTIVE_SCOPE_BACKEND" | "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND")
    domain="${2:-}"
    directive="${3:-}"
    shift 3 || true
    value="$*"
    ;;
  "$NGINX_DIRECTIVE_SCOPE_PORT" | "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT")
    domain="${2:-}"
    listen_port="${3:-}"
    directive="${4:-}"
    shift 4 || true
    value="$*"
    ;;
  "$NGINX_DIRECTIVE_SCOPE_PATH")
    domain="${2:-}"
    listen_port="${3:-}"
    path_prefix="${4:-}"
    directive="${5:-}"
    shift 5 || true
    value="$*"
    ;;
  esac

  if [ -z "$directive" ] || [ -z "$value" ]; then
    echo "$usage_msg"
    return 1
  fi

  if ! nginx_directives_resolve_scope_target scope domain listen_port path_prefix "$scope" "$domain" "$listen_port" "$path_prefix"; then
    return 1
  fi

  if ! nginx_directive_validate_name_token "$directive"; then
    echo "[Error] Invalid directive token: ${directive}" >&2
    return 1
  fi

  if ! nginx_directive_catalog_validate_for_scope "$scope" "$directive" "$value"; then
    return 1
  fi

  if ! nginx_directive_preflight_required_module "$scope" "$directive"; then
    return 1
  fi

  if ! nginx_directives_require_generic_write_allowed "$directive"; then
    return 1
  fi

  begin_transaction "set_nginx_directive_${scope}_${directive}" "$CONFIG_DIR"
  if ! nginx_directives_state_upsert "$scope" "$domain" "$listen_port" "$path_prefix" "$NGINX_DIRECTIVE_MODE_MANAGED" "$directive" "$value"; then
    _rollback_handler
  fi
  if ! update_nginx_config; then
    _rollback_handler
  fi
  end_transaction_success

  if [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_GLOBAL" ]; then
    echo "[Info] Set global nginx directive '${directive}' to '${value}'."
  elif [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_BACKEND" ]; then
    echo "[Info] Set backend nginx directive '${directive}' for '${domain}' to '${value}'."
  elif [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_PORT" ]; then
    echo "[Info] Set port nginx directive '${directive}' for '${domain}:${listen_port}' to '${value}'."
  elif [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_PATH" ]; then
    echo "[Info] Set path nginx directive '${directive}' for '${domain}:${listen_port}${path_prefix}' to '${value}'."
  elif [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL" ]; then
    echo "[Info] Set stream-global nginx directive '${directive}' to '${value}'."
  elif [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND" ]; then
    echo "[Info] Set stream-backend nginx directive '${directive}' for '${domain}' to '${value}'."
  else
    echo "[Info] Set stream-port nginx directive '${directive}' for '${domain}:${listen_port}' to '${value}'."
  fi
}
