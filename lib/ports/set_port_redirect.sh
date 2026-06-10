# shellcheck shell=bash

_SPR_REWRITE_DOMAIN=""
_SPR_REWRITE_PORT=""
_SPR_REWRITE_FLAG=""
_SPR_REWRITE_CODE=""
_SPR_REWRITE_APPLIED="no"

function _set_port_redirect_rewrite_row_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
    [ "$STATE_BP_DOMAIN" = "${_SPR_REWRITE_DOMAIN:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_SPR_REWRITE_PORT:-}" ]; then
    CSV_FIELDS[11]="${_SPR_REWRITE_FLAG:-}"
    CSV_FIELDS[12]="${_SPR_REWRITE_CODE:-}"
    _SPR_REWRITE_APPLIED="yes"
  fi
  return 0
}

function set_port_redirect() {
  local domain="${1:-}" port="${2:-}" on_off="${3:-}" code="${4:-301}"
  local target_port=""
  if [ -z "$domain" ] || [ -z "$port" ] || [ -z "$on_off" ]; then
    echo "[Usage] set-port-redirect <domain> <port> <on|off> [301|302|308[:target_port]]"
    exit 1
  fi
  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi
  if ! is_yes_no "${on_off/yes/on}"; then
    if [[ "$on_off" != "on" && "$on_off" != "off" ]]; then
      echo "[Error] Redirect flag must be on|off" >&2
      exit 1
    fi
  fi
  [[ "$on_off" = yes ]] && on_off="on"
  if [ "$on_off" = "on" ]; then
    if [[ "$code" == *:* ]]; then
      target_port="${code#*:}"
      code="${code%%:*}"
      [ -z "$code" ] && code="301"
      if [ -n "$target_port" ] && ! is_valid_port "$target_port"; then
        echo "[Error] Invalid redirect target port: $target_port" >&2
        exit 1
      fi
    fi
    if ! is_status_code "$code"; then
      echo "[Error] Invalid status code: $code" >&2
      exit 1
    fi
    case "$code" in 301 | 302 | 308) ;; *)
      echo "[Error] Only 301, 302, or 308 supported" >&2
      exit 1
      ;;
    esac
  else
    code=""
  fi
  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Error] No port mappings configured." >&2
    exit 1
  }
  # Ensure mapping exists and is HTTP
  local line="" line_no=0 proto=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      echo "[Error] Invalid backend_ports.csv row at line ${line_no}." >&2
      exit 1
    fi
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
      [ "$STATE_BP_DOMAIN" = "$domain" ] &&
      [ "$STATE_BP_LISTEN_PORT" = "$port" ]; then
      proto="$STATE_BP_PROTOCOL"
      break
    fi
  done <"$BACKEND_PORTS_FILE"
  [ -n "$proto" ] || {
    echo "[Error] Port mapping for $domain on $port not found." >&2
    exit 1
  }
  if [ "$proto" != "http" ]; then
    echo "[Error] Redirect supported only for HTTP mappings." >&2
    exit 1
  fi
  local code_store="$code"
  if [ -n "$target_port" ]; then
    code_store="${code}:${target_port}"
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "set_port_redirect_${domain}_${port}"; then
    exit 1
  fi
  _SPR_REWRITE_DOMAIN="$domain"
  _SPR_REWRITE_PORT="$port"
  _SPR_REWRITE_FLAG="$on_off"
  _SPR_REWRITE_CODE="$code_store"
  _SPR_REWRITE_APPLIED="no"
  if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _set_port_redirect_rewrite_row_cb; then
    return 1
  fi
  if [ "$_SPR_REWRITE_APPLIED" != "yes" ]; then
    echo "[Error] Port mapping for $domain on $port not found." >&2
    return 1
  fi
  local display="$code_store"
  [ -z "$display" ] && display="off"
  echo "[Info] Redirect ${on_off} for ${domain} on port ${port}${display:+ (${display})}."
  create_backup "" "SetPortRedirect_${domain}_${port}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
