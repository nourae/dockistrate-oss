# shellcheck shell=bash

_PORT_HTTP3_REWRITE_PORT=""
_PORT_HTTP3_REWRITE_ENABLED="off"
_PORT_HTTP3_REWRITE_ALT_SVC="auto"
_PORT_HTTP3_REWRITE_APPLIED="no"

function _set_port_http3_rewrite_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
    [ "$STATE_BP_PROTOCOL" = "https" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_PORT_HTTP3_REWRITE_PORT:-}" ]; then
    CSV_FIELDS[13]="${_PORT_HTTP3_REWRITE_ENABLED:-off}"
    CSV_FIELDS[14]="${_PORT_HTTP3_REWRITE_ALT_SVC:-auto}"
    _PORT_HTTP3_REWRITE_APPLIED="yes"
  fi
  return 0
}

function _port_http3_target_exists() {
  local listen_port="${1:-}"
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
    [ "$STATE_BP_PROTOCOL" = "https" ] || continue
    [ "$STATE_BP_LISTEN_PORT" = "$listen_port" ] || continue
    return 0
  done <"$BACKEND_PORTS_FILE"
  return 1
}

function set_port_http3() {
  local listen_port="${1:-}" enabled_raw="${2:-}" alt_svc_raw="${3:-auto}"
  if [ -z "$listen_port" ] || [ -z "$enabled_raw" ]; then
    echo "[Usage] set-port-http3 <port> <on|off> [alt-svc auto|off|custom]"
    exit 1
  fi

  require_valid_port "$listen_port"
  _parse_http3_flag "$enabled_raw" || exit 1
  _parse_alt_svc_mode "$alt_svc_raw" || exit 1

  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Error] No port mappings configured." >&2
    exit 1
  }

  if ! _port_http3_target_exists "$listen_port"; then
    echo "[Error] HTTPS mapping for port '$listen_port' was not found." >&2
    exit 1
  fi

  if [ "$PORT_HTTP3_FLAG" = "on" ]; then
    if _udp_mapping_listen_in_use "$listen_port"; then
      echo "[Error] UDP port ${listen_port} is already in use by another mapping." >&2
      exit 1
    fi
    if ! assert_host_port_available_or_fail "$listen_port" "udp"; then
      exit 1
    fi
  fi

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "set_port_http3_${listen_port}"; then
    exit 1
  fi
  _PORT_HTTP3_REWRITE_PORT="$listen_port"
  _PORT_HTTP3_REWRITE_ENABLED="$PORT_HTTP3_FLAG"
  _PORT_HTTP3_REWRITE_ALT_SVC="$PORT_ALT_SVC_MODE"
  _PORT_HTTP3_REWRITE_APPLIED="no"

  if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _set_port_http3_rewrite_cb; then
    return 1
  fi

  if [ "$_PORT_HTTP3_REWRITE_APPLIED" != "yes" ]; then
    echo "[Error] HTTPS mapping for port '$listen_port' was not found." >&2
    exit 1
  fi

  echo "[Info] Updated HTTP/3 for HTTPS port ${listen_port}: http3=${PORT_HTTP3_FLAG} alt-svc=${PORT_ALT_SVC_MODE}."
  log_msg "Updated HTTP/3 settings for HTTPS port ${listen_port}: http3=${PORT_HTTP3_FLAG} alt-svc=${PORT_ALT_SVC_MODE}"
  create_backup "" "SetPortHttp3_${listen_port}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}

function list_port_http3() {
  local filter_port="${1:-}"
  local line="" line_no=0
  local printed=0

  if [ -n "$filter_port" ]; then
    require_valid_port "$filter_port"
  fi

  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Info] No HTTPS port mappings configured."
    return 0
  }

  local rows=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
    [ "$STATE_BP_PROTOCOL" = "https" ] || continue
    if [ -n "$filter_port" ] && [ "$STATE_BP_LISTEN_PORT" != "$filter_port" ]; then
      continue
    fi

    local current_http3="${STATE_BP_HTTP3:-off}" current_alt_svc="${STATE_BP_ALT_SVC:-auto}"
    rows+="${STATE_BP_LISTEN_PORT},${current_http3},${current_alt_svc}"$'\n'
  done <"$BACKEND_PORTS_FILE"

  if [ -z "$rows" ]; then
    if [ -n "$filter_port" ]; then
      echo "[Info] No HTTPS mapping found for port ${filter_port}."
    else
      echo "[Info] No HTTPS port mappings configured."
    fi
    return 0
  fi

  echo "Port | HTTP3 | Alt-Svc"
  echo "----------------------"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq 3 ] || continue
    printf '%s | %s | %s\n' "${CSV_FIELDS[0]}" "${CSV_FIELDS[1]}" "${CSV_FIELDS[2]}"
    printed=1
  done <<<"$(printf '%s' "$rows" | awk -F',' '!seen[$1]++' | sort -t',' -k1,1n)"

  [ "$printed" -eq 1 ] || echo "[Info] No HTTPS port mappings configured."
}
