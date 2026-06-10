# shellcheck shell=bash

function nginx_directive_validate_name_token() {
  local directive="${1:-}"
  [[ "$directive" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

function nginx_directive_validate_raw_value() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  case "$value" in
  *";"* | *"{"* | *"}"*)
    return 1
    ;;
  esac
  return 0
}

function _nginx_directive_validate_size_value() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  [[ "$value" =~ [[:space:]] ]] && return 1
  [[ "$value" =~ ^[0-9]+([kKmMgG])?$ ]]
}

function _nginx_directive_validate_time_value() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  [[ "$value" =~ [[:space:]] ]] && return 1
  [[ "$value" =~ ^[0-9]+(ms|s|m|h|d|w|y)?$ ]]
}

function _nginx_directive_validate_on_off_value() {
  local value="${1:-}"
  is_on_off "$value"
}

function _nginx_directive_validate_integer_value() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  [[ "$value" =~ ^[0-9]+$ ]]
}

function _nginx_directive_validate_count_size_pair() {
  local value="${1:-}"
  local count size extra
  count="${value%% *}"
  size="${value#* }"
  extra=""

  [ -n "$count" ] || return 1
  [ -n "$size" ] || return 1
  if [ "$size" = "$value" ]; then
    return 1
  fi
  if [[ ! "$count" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [ "$count" -lt 1 ]; then
    return 1
  fi

  if [[ "$size" == *" "* ]]; then
    extra="${size#* }"
    if [ -n "$extra" ]; then
      return 1
    fi
  fi

  _nginx_directive_validate_size_value "$size"
}

function _nginx_directive_validate_size_or_rate_value() {
  local value="${1:-}"
  _nginx_directive_validate_size_value "$value"
}

function nginx_directive_catalog_type() {
  local directive="${1:-}"
  nginx_directive_catalog_type_for_scope "$NGINX_DIRECTIVE_SCOPE_GLOBAL" "$directive"
}

function nginx_directive_catalog_type_for_scope() {
  local scope="${1:-}" directive="${2:-}" context=""
  context="$(nginx_directive_scope_context "$scope" 2>/dev/null || true)"
  [ -n "$context" ] || context="$NGINX_DIRECTIVE_CONTEXT_HTTP"

  case "$context:$directive" in
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:client_max_body_size") printf '%s\n' "size" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:client_body_buffer_size") printf '%s\n' "size" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:client_header_buffer_size") printf '%s\n' "size" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:large_client_header_buffers") printf '%s\n' "count_size_pair" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:proxy_connect_timeout") printf '%s\n' "time" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:proxy_read_timeout") printf '%s\n' "time" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:proxy_send_timeout") printf '%s\n' "time" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:send_timeout") printf '%s\n' "time" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:proxy_buffering") printf '%s\n' "on_off" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:proxy_request_buffering") printf '%s\n' "on_off" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:proxy_buffer_size") printf '%s\n' "size" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:proxy_buffers") printf '%s\n' "count_size_pair" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:proxy_busy_buffers_size") printf '%s\n' "size" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:underscores_in_headers") printf '%s\n' "on_off" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:ignore_invalid_headers") printf '%s\n' "on_off" ;;
  "$NGINX_DIRECTIVE_CONTEXT_HTTP:server_tokens") printf '%s\n' "on_off" ;;

  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_connect_timeout") printf '%s\n' "time" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_timeout") printf '%s\n' "time" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_protocol") printf '%s\n' "on_off" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_socket_keepalive") printf '%s\n' "on_off" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_buffer_size") printf '%s\n' "size" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_download_rate") printf '%s\n' "size_or_rate" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_upload_rate") printf '%s\n' "size_or_rate" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_requests") printf '%s\n' "integer" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_responses") printf '%s\n' "integer" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_next_upstream") printf '%s\n' "on_off" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_next_upstream_timeout") printf '%s\n' "time" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:proxy_next_upstream_tries") printf '%s\n' "integer" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:preread_buffer_size") printf '%s\n' "size" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:preread_timeout") printf '%s\n' "time" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:tcp_nodelay") printf '%s\n' "on_off" ;;
  "$NGINX_DIRECTIVE_CONTEXT_STREAM:ssl_preread") printf '%s\n' "on_off" ;;
  *)
    return 1
    ;;
  esac
}

function nginx_directive_catalog_validate_for_scope() {
  local scope="${1:-}" directive="${2:-}" value="${3:-}" context="" dtype=""
  local expected_scope="${scope:-$NGINX_DIRECTIVE_SCOPE_GLOBAL}"

  if ! expected_scope="$(nginx_directive_normalize_scope "$expected_scope" 2>/dev/null)"; then
    expected_scope="$NGINX_DIRECTIVE_SCOPE_GLOBAL"
  fi

  context="$(nginx_directive_scope_context "$expected_scope" 2>/dev/null || true)"
  [ -n "$context" ] || context="$NGINX_DIRECTIVE_CONTEXT_HTTP"

  if ! nginx_directive_validate_name_token "$directive"; then
    echo "[Error] Invalid directive token: ${directive}" >&2
    return 1
  fi

  dtype="$(nginx_directive_catalog_type_for_scope "$expected_scope" "$directive" 2>/dev/null || true)"
  if [ -z "$dtype" ]; then
    echo "[Error] Unsupported managed directive '${directive}' for scope '${expected_scope}'. Use set-nginx-directive-raw for advanced directives." >&2
    return 1
  fi

  if ! nginx_directive_validate_raw_value "$value"; then
    echo "[Error] Invalid directive value for '${directive}'. Control characters and ';', '{', '}' are not allowed." >&2
    return 1
  fi

  case "$dtype" in
  size)
    if ! _nginx_directive_validate_size_value "$value"; then
      echo "[Error] Directive '${directive}' expects a size value (for example: 8k, 16m)." >&2
      return 1
    fi
    ;;
  size_or_rate)
    if ! _nginx_directive_validate_size_or_rate_value "$value"; then
      echo "[Error] Directive '${directive}' expects a size/rate token (for example: 64k, 1m)." >&2
      return 1
    fi
    ;;
  time)
    if ! _nginx_directive_validate_time_value "$value"; then
      echo "[Error] Directive '${directive}' expects a time value (for example: 30s, 5m)." >&2
      return 1
    fi
    ;;
  on_off)
    if ! _nginx_directive_validate_on_off_value "$value"; then
      echo "[Error] Directive '${directive}' expects 'on' or 'off'." >&2
      return 1
    fi
    ;;
  integer)
    if ! _nginx_directive_validate_integer_value "$value"; then
      echo "[Error] Directive '${directive}' expects a non-negative integer value." >&2
      return 1
    fi
    ;;
  count_size_pair)
    if ! _nginx_directive_validate_count_size_pair "$value"; then
      echo "[Error] Directive '${directive}' expects '<count> <size>' (for example: 4 16k)." >&2
      return 1
    fi
    ;;
  *)
    echo "[Error] Unknown directive type '${dtype}' for '${directive}'." >&2
    return 1
    ;;
  esac

  return 0
}

function nginx_directive_catalog_validate() {
  local scope="${1:-}" directive="${2:-}" value="${3:-}"
  if [ "$#" -lt 3 ]; then
    scope="$NGINX_DIRECTIVE_SCOPE_GLOBAL"
    directive="${1:-}"
    value="${2:-}"
  fi
  nginx_directive_catalog_validate_for_scope "$scope" "$directive" "$value"
}

function nginx_directive_catalog_keys_for_scope() {
  local scope="${1:-}" context=""
  local expected_scope="${scope:-$NGINX_DIRECTIVE_SCOPE_GLOBAL}"
  if ! expected_scope="$(nginx_directive_normalize_scope "$expected_scope" 2>/dev/null)"; then
    expected_scope="$NGINX_DIRECTIVE_SCOPE_GLOBAL"
  fi
  context="$(nginx_directive_scope_context "$expected_scope" 2>/dev/null || true)"
  [ -n "$context" ] || context="$NGINX_DIRECTIVE_CONTEXT_HTTP"

  if [ "$context" = "$NGINX_DIRECTIVE_CONTEXT_STREAM" ]; then
    cat <<'EOF_KEYS'
proxy_connect_timeout
proxy_timeout
proxy_protocol
proxy_socket_keepalive
proxy_buffer_size
proxy_download_rate
proxy_upload_rate
proxy_requests
proxy_responses
proxy_next_upstream
proxy_next_upstream_timeout
proxy_next_upstream_tries
preread_buffer_size
preread_timeout
tcp_nodelay
ssl_preread
EOF_KEYS
    return 0
  fi

  cat <<'EOF_KEYS'
client_max_body_size
client_body_buffer_size
client_header_buffer_size
large_client_header_buffers
proxy_connect_timeout
proxy_read_timeout
proxy_send_timeout
send_timeout
proxy_buffering
proxy_request_buffering
proxy_buffer_size
proxy_buffers
proxy_busy_buffers_size
underscores_in_headers
ignore_invalid_headers
server_tokens
EOF_KEYS
}

function nginx_directive_catalog_keys() {
  nginx_directive_catalog_keys_for_scope "$NGINX_DIRECTIVE_SCOPE_GLOBAL"
}

function nginx_directive_catalog_contains_for_scope() {
  local scope="${1:-}" directive="${2:-}" item=""
  for item in $(nginx_directive_catalog_keys_for_scope "$scope"); do
    if [ "$item" = "$directive" ]; then
      return 0
    fi
  done
  return 1
}

function nginx_directive_catalog_contains() {
  local directive="${1:-}"
  nginx_directive_catalog_contains_for_scope "$NGINX_DIRECTIVE_SCOPE_GLOBAL" "$directive"
}
