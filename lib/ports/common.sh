# shellcheck shell=bash


function _sanitize_path_for_id() {
  local value="${1:-}"
  value="${value//\//_}"
  value="${value//[^A-Za-z0-9_-]/_}"
  echo "$value"
}


function _stream_listen_in_use() {
  local port="${1:-}" protocol="${2:-tcp}" skip_domain="${3:-}" skip_port="${4:-}"
  case "$protocol" in
  tcp | udp) ;;
  *)
    return 1
    ;;
  esac
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
    [ "${STATE_BP_LISTEN_PORT:-}" = "$port" ] || continue
    if [ -n "$skip_domain" ] && [ -n "$skip_port" ] &&
      [ "${STATE_BP_DOMAIN:-}" = "$skip_domain" ] &&
      [ "${STATE_BP_LISTEN_PORT:-}" = "$skip_port" ]; then
      continue
    fi

    local row_protocol="${STATE_BP_PROTOCOL:-}"
    case "$protocol" in
    tcp)
      if [ "$row_protocol" = "tcp" ]; then
        return 0
      fi
      ;;
    udp)
      if [ "$row_protocol" = "udp" ]; then
        return 0
      fi
      if [ "$row_protocol" = "https" ] && [ "${STATE_BP_HTTP3:-off}" = "on" ]; then
        return 0
      fi
      ;;
    esac
  done <"$BACKEND_PORTS_FILE"
  return 1
}

function _udp_mapping_listen_in_use() {
  local port="${1:-}" skip_domain="${2:-}" skip_port="${3:-}"
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
    [ "${STATE_BP_LISTEN_PORT:-}" = "$port" ] || continue
    [ "${STATE_BP_PROTOCOL:-}" = "udp" ] || continue
    if [ -n "$skip_domain" ] && [ -n "$skip_port" ] &&
      [ "${STATE_BP_DOMAIN:-}" = "$skip_domain" ] &&
      [ "${STATE_BP_LISTEN_PORT:-}" = "$skip_port" ]; then
      continue
    fi
    return 0
  done <"$BACKEND_PORTS_FILE"
  return 1
}

function _tcp_listen_in_use() {
  local port="${1:-}"
  _stream_listen_in_use "$port" "tcp"
}

function _udp_listen_in_use() {
  local port="${1:-}"
  _stream_listen_in_use "$port" "udp"
}


function is_valid_header_set_name() {
  local name="${1:-}"
  [[ "$name" =~ ^[-A-Za-z0-9_]+$ ]]
}


function is_valid_path_prefix() {
  local prefix="${1:-}"
  [ -n "$prefix" ] || return 1
  [[ "$prefix" == /* ]] || return 1
  if printf '%s' "$prefix" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return 1
  fi
  if [[ "$prefix" =~ [[:space:]] ]]; then
    return 1
  fi
  case "$prefix" in
  *\#* | *';'* | *'{'* | *'}'*)
    return 1
    ;;
  esac
  if [[ "$prefix" == *,* ]]; then
    return 1
  fi
  if [[ "$prefix" == *\"* ]]; then
    return 1
  fi
  if [[ "$prefix" == *\'* ]]; then
    return 1
  fi
  if [[ "$prefix" == *\\* ]]; then
    return 1
  fi
  return 0
}


function _parse_path_ws() {
  local raw="${1:-inherit}"
  case "$raw" in
  inherit | INHERIT | "") PATH_WS_FLAG="inherit" ;;
  yes | YES) PATH_WS_FLAG="yes" ;;
  no | NO) PATH_WS_FLAG="no" ;;
  *)
    echo "[Error] WebSocket flag must be yes, no, or inherit" >&2
    return 1
    ;;
  esac
  return 0
}


function _parse_path_redirect() {
  local raw="${1:-inherit}"
  case "$raw" in
  inherit | INHERIT | "")
    PATH_REDIRECT_FLAG="inherit"
    PATH_REDIRECT_CODE=""
    ;;
  off | OFF | no | NO)
    PATH_REDIRECT_FLAG="off"
    PATH_REDIRECT_CODE=""
    ;;
  301 | 302 | 308)
    PATH_REDIRECT_FLAG="on"
    PATH_REDIRECT_CODE="$raw"
    ;;
  *)
    echo "[Error] Redirect must be inherit, off, or 301|302|308" >&2
    return 1
    ;;
  esac
  return 0
}

function _parse_path_match_mode() {
  local raw="${1:-prefix}"
  case "$raw" in
  prefix | exact | regex)
    PATH_MATCH_MODE="$raw"
    ;;
  *)
    echo "[Error] Path match mode must be prefix, exact, or regex." >&2
    return 1
    ;;
  esac
  return 0
}

function _parse_path_priority() {
  local raw="${1:-100}"
  if ! is_valid_path_priority "$raw"; then
    echo "[Error] Path priority must be a positive integer." >&2
    return 1
  fi
  PATH_PRIORITY="$raw"
  return 0
}

function _parse_path_target() {
  local raw="${1:-}"
  if ! is_valid_path_target "$raw"; then
    echo "[Error] Invalid path target '${raw}'. Use an upstream port or host:port." >&2
    return 1
  fi
  PATH_TARGET="$raw"
  return 0
}

function _parse_path_rewrite() {
  local raw="${1:-none}"
  if ! is_valid_path_rewrite_spec "$raw"; then
    echo "[Error] Invalid path rewrite '${raw}'. Use none, strip-prefix, or replace:/new/path." >&2
    return 1
  fi
  PATH_REWRITE="$raw"
  return 0
}

function _parse_path_reason() {
  local raw="${1:--}"
  if ! is_valid_reason_value "$raw"; then
    echo "[Error] Invalid path reason value." >&2
    return 1
  fi
  PATH_REASON="$raw"
  return 0
}

function _parse_path_loc() {
  local raw="${1:-auto}"
  if ! is_valid_loc_value "$raw"; then
    echo "[Error] Invalid path loc value." >&2
    return 1
  fi
  PATH_LOC="$raw"
  return 0
}

function _parse_http3_flag() {
  local raw="${1:-off}"
  case "$raw" in
  on | ON | yes | YES)
    PORT_HTTP3_FLAG="on"
    ;;
  off | OFF | no | NO | "")
    PORT_HTTP3_FLAG="off"
    ;;
  *)
    echo "[Error] HTTP/3 must be on|off." >&2
    return 1
    ;;
  esac
  return 0
}

function _parse_alt_svc_mode() {
  local raw="${1:-auto}"
  if [ -z "$raw" ]; then
    raw="auto"
  fi
  case "$raw" in
  auto | off)
    PORT_ALT_SVC_MODE="$raw"
    return 0
    ;;
  esac
  if ! is_valid_alt_svc_mode "$raw"; then
    echo "[Error] Invalid alt-svc value." >&2
    return 1
  fi
  PORT_ALT_SVC_MODE="$raw"
  return 0
}

function get_port_http3_state() {
  local listen_port="${1:-}" out_http3="${2:-}" out_alt_svc="${3:-}"
  local line="" line_no=0
  local http3_value="off" alt_svc_value="auto"

  require_valid_var_name "$out_http3" || return 1
  require_valid_var_name "$out_alt_svc" || return 1
  is_valid_port "$listen_port" || return 1
  [ -f "$BACKEND_PORTS_FILE" ] || {
    printf -v "$out_http3" '%s' "$http3_value"
    printf -v "$out_alt_svc" '%s' "$alt_svc_value"
    return 0
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
    [ "$STATE_BP_LISTEN_PORT" = "$listen_port" ] || continue
    [ "$STATE_BP_PROTOCOL" = "https" ] || continue
    http3_value="${STATE_BP_HTTP3:-off}"
    alt_svc_value="${STATE_BP_ALT_SVC:-auto}"
    break
  done <"$BACKEND_PORTS_FILE"

  printf -v "$out_http3" '%s' "$http3_value"
  printf -v "$out_alt_svc" '%s' "$alt_svc_value"
  return 0
}


function _require_port_mapping_for_path() {
  local domain="$1" port="$2"
  resolve_backend_domain domain "$domain"
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    return 1
  fi
  local proto="" found="false"
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    if [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] &&
      [ "${STATE_BP_DOMAIN:-}" = "$domain" ] &&
      [ "${STATE_BP_LISTEN_PORT:-}" = "$port" ]; then
      proto="${STATE_BP_PROTOCOL:-}"
      found="true"
      break
    fi
  done <"$BACKEND_PORTS_FILE"
  [ "$found" = "true" ] || {
    echo "[Error] Port mapping for $domain on $port not found." >&2
    return 1
  }
  if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ]; then
    echo "[Error] Path overrides are not supported for TCP/UDP mappings." >&2
    return 1
  fi
  return 0
}


function get_backend_ws_flag() {
  local domain="${1:-}" port="${2:-}"
  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi
  local val="no"
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      if ! state_backend_ports_parse_line "$line"; then
        continue
      fi
      if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
        [ "$STATE_BP_DOMAIN" = "$domain" ] &&
        [ "$STATE_BP_LISTEN_PORT" = "$port" ]; then
        val="${STATE_BP_WS:-no}"
        break
      fi
    done <"$BACKEND_PORTS_FILE"
  fi
  echo "$val"
}


_SWF_REWRITE_DOMAIN=""
_SWF_REWRITE_PORT=""
_SWF_REWRITE_FLAG=""
_SWF_REWRITE_APPLIED="no"

function _set_ws_flag_rewrite_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
    [ "$STATE_BP_DOMAIN" = "${_SWF_REWRITE_DOMAIN:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_SWF_REWRITE_PORT:-}" ]; then
    CSV_FIELDS[10]="${_SWF_REWRITE_FLAG:-}"
    _SWF_REWRITE_APPLIED="yes"
  fi
  return 0
}


function _set_ws_flag() {
  local domain="${1:-}"
  local port="${2:-}"
  local flag="${3:-}"
  local started_txn=false
  if [ -z "$domain" ] || [ -z "$port" ]; then
    echo "[Usage] ${flag}-ws <domain> <port>"
    exit 1
  fi
  resolve_backend_domain domain "$domain" true
  require_valid_port "$port"
  if ! is_yes_no "$flag"; then
    echo "[Error] Invalid ws flag: $flag" >&2
    exit 1
  fi

  local updated="no"
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    if ! _config_begin_transaction_if_needed started_txn "set_ws_${domain}_${port}_${flag}"; then
      exit 1
    fi
    _SWF_REWRITE_DOMAIN="$domain"
    _SWF_REWRITE_PORT="$port"
    _SWF_REWRITE_FLAG="$flag"
    _SWF_REWRITE_APPLIED="no"
    if csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _set_ws_flag_rewrite_cb; then
      if [ "$_SWF_REWRITE_APPLIED" = "yes" ]; then
        updated="yes"
      fi
    else
      return 1
    fi
  fi

  if [ "$updated" = "no" ]; then
    echo "[Error] Port mapping for $domain on port $port not found." >&2
    exit 1
  fi

  local action backup
  if [ "$flag" = "yes" ]; then
    action="enabled"
    backup="EnableWS"
  else
    action="disabled"
    backup="DisableWS"
  fi
  echo "[Info] WebSocket ${action} for $domain on port $port."
  log_msg "WS ${action} ${domain}:${port}"
  create_backup "" "${backup}_${domain}_${port}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
