# shellcheck shell=bash

NGINX_DIRECTIVE_MODE_MANAGED="managed"
NGINX_DIRECTIVE_MODE_RAW="raw"
NGINX_DIRECTIVE_SCOPE_GLOBAL="global"
NGINX_DIRECTIVE_SCOPE_BACKEND="backend"
NGINX_DIRECTIVE_SCOPE_PORT="port"
NGINX_DIRECTIVE_SCOPE_PATH="path"
NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL="stream-global"
NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND="stream-backend"
NGINX_DIRECTIVE_SCOPE_STREAM_PORT="stream-port"
NGINX_DIRECTIVE_CONTEXT_HTTP="http"
NGINX_DIRECTIVE_CONTEXT_STREAM="stream"

function nginx_directive_normalize_scope() {
  local scope="${1:-}"
  case "$(printf '%s' "$scope" | tr '[:upper:]' '[:lower:]')" in
  global) printf '%s\n' "$NGINX_DIRECTIVE_SCOPE_GLOBAL" ;;
  backend) printf '%s\n' "$NGINX_DIRECTIVE_SCOPE_BACKEND" ;;
  port) printf '%s\n' "$NGINX_DIRECTIVE_SCOPE_PORT" ;;
  path) printf '%s\n' "$NGINX_DIRECTIVE_SCOPE_PATH" ;;
  stream-global) printf '%s\n' "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL" ;;
  stream-backend) printf '%s\n' "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND" ;;
  stream-port) printf '%s\n' "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT" ;;
  *) return 1 ;;
  esac
}

function nginx_directive_normalize_mode() {
  local mode="${1:-}"
  case "$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')" in
  managed) printf '%s\n' "$NGINX_DIRECTIVE_MODE_MANAGED" ;;
  raw) printf '%s\n' "$NGINX_DIRECTIVE_MODE_RAW" ;;
  *) return 1 ;;
  esac
}

function nginx_directive_owner_command() {
  local directive="${1:-}"
  case "$directive" in
  server_tokens)
    printf '%s\n' "control-server-tokens"
    ;;
  ssl_protocols)
    printf '%s\n' "set-tls-protocols / set-port-tls-protocols"
    ;;
  ssl_ciphers)
    printf '%s\n' "set-tls-ciphers / set-port-tls-ciphers"
    ;;
  *)
    return 1
    ;;
  esac
}

function nginx_directive_is_owned() {
  local directive="${1:-}"
  if nginx_directive_owner_command "$directive" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

function nginx_directive_strict_value() {
  local current="${NGINX_DIRECTIVE_STRICT:-on}"
  current="$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')"
  case "$current" in
  on | off)
    printf '%s\n' "$current"
    ;;
  *)
    printf '%s\n' "on"
    ;;
  esac
}

function nginx_directive_strict_is_on() {
  [ "$(nginx_directive_strict_value)" = "on" ]
}

function nginx_directive_scope_requires_domain() {
  local scope="${1:-}"
  [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_BACKEND" ] ||
    [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_PORT" ] ||
    [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_PATH" ] ||
    [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND" ] ||
    [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT" ]
}

function nginx_directive_scope_requires_port() {
  local scope="${1:-}"
  [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_PORT" ] ||
    [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_PATH" ] ||
    [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT" ]
}

function nginx_directive_scope_requires_path() {
  local scope="${1:-}"
  [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_PATH" ]
}

function nginx_directive_scope_context() {
  local scope="${1:-}"
  case "$scope" in
  "$NGINX_DIRECTIVE_SCOPE_GLOBAL" | "$NGINX_DIRECTIVE_SCOPE_BACKEND" | "$NGINX_DIRECTIVE_SCOPE_PORT" | "$NGINX_DIRECTIVE_SCOPE_PATH")
    printf '%s\n' "$NGINX_DIRECTIVE_CONTEXT_HTTP"
    ;;
  "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL" | "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND" | "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT")
    printf '%s\n' "$NGINX_DIRECTIVE_CONTEXT_STREAM"
    ;;
  *)
    return 1
    ;;
  esac
}

function nginx_directive_scope_is_stream() {
  local scope="${1:-}" context=""
  context="$(nginx_directive_scope_context "$scope" 2>/dev/null || true)"
  [ "$context" = "$NGINX_DIRECTIVE_CONTEXT_STREAM" ]
}

function nginx_directive_scope_allows_dedicated_host_target() {
  local scope="${1:-}"
  if nginx_directive_scope_is_stream "$scope"; then
    return 1
  fi
  return 0
}

function nginx_directive_is_stream_scope_selector() {
  local scope="${1:-}"
  [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL" ] ||
    [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_BACKEND" ] ||
    [ "$scope" = "$NGINX_DIRECTIVE_SCOPE_STREAM_PORT" ]
}

function nginx_directive_normalize_target_domain() {
  local domain="${1:-}"
  if [ -z "$domain" ]; then
    return 1
  fi
  domain="$(normalize_domain "$domain")"
  if ! is_valid_domain "$domain"; then
    return 1
  fi
  printf '%s\n' "$domain"
}

function nginx_directive_target_domain_exists() {
  local scope="${1:-}" domain="${2:-}"
  if [ -z "$domain" ]; then
    domain="$scope"
    scope=""
  fi

  domain="$(normalize_domain "$domain")"

  if [ -n "$scope" ] && nginx_directive_scope_is_stream "$scope"; then
    if backend_exists "$domain"; then
      return 0
    fi
    return 1
  fi

  if backend_exists "$domain" || dedicated_host_exists "$domain"; then
    return 0
  fi
  return 1
}

function nginx_directive_resolve_owner_guidance() {
  local directive="${1:-}"
  local owner=""
  owner="$(nginx_directive_owner_command "$directive" 2>/dev/null || true)"
  if [ -n "$owner" ]; then
    printf '%s\n' "$owner"
  else
    printf '%s\n' ""
  fi
}
