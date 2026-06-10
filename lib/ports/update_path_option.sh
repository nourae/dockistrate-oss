# shellcheck shell=bash

_UPO_REWRITE_DOMAIN=""
_UPO_REWRITE_OLD_PATH=""
_UPO_REWRITE_OLD_PORT=""
_UPO_REWRITE_NEW_PATH=""
_UPO_REWRITE_NEW_PORT=""
_UPO_REWRITE_HEADER=""
_UPO_REWRITE_WS=""
_UPO_REWRITE_REDIRECT=""
_UPO_REWRITE_CODE=""
_UPO_REWRITE_MATCH=""
_UPO_REWRITE_PRIORITY=""
_UPO_REWRITE_TARGET=""
_UPO_REWRITE_REWRITE=""
_UPO_REWRITE_REASON=""
_UPO_REWRITE_LOC=""
_UPO_REWRITE_APPLIED="no"

function _update_path_option_rewrite_row_cb() {
  state_backend_ports_assign_from_fields || return 1
  if [ "$STATE_BP_RECORD_TYPE" = "path" ] &&
    [ "$STATE_BP_DOMAIN" = "${_UPO_REWRITE_DOMAIN:-}" ] &&
    [ "$STATE_BP_PATH_PREFIX" = "${_UPO_REWRITE_OLD_PATH:-}" ] &&
    [ "$STATE_BP_LISTEN_PORT" = "${_UPO_REWRITE_OLD_PORT:-}" ]; then
    CSV_FIELDS[4]="${_UPO_REWRITE_NEW_PATH:-}"
    CSV_FIELDS[5]="${_UPO_REWRITE_HEADER:-}"
    CSV_FIELDS[6]="${_UPO_REWRITE_NEW_PORT:-}"
    CSV_FIELDS[10]="${_UPO_REWRITE_WS:-}"
    CSV_FIELDS[11]="${_UPO_REWRITE_REDIRECT:-}"
    CSV_FIELDS[12]="${_UPO_REWRITE_CODE:-}"
    CSV_FIELDS[15]="${_UPO_REWRITE_MATCH:-prefix}"
    CSV_FIELDS[16]="${_UPO_REWRITE_PRIORITY:-100}"
    CSV_FIELDS[17]="${_UPO_REWRITE_TARGET:-}"
    CSV_FIELDS[18]="${_UPO_REWRITE_REWRITE:-none}"
    CSV_FIELDS[19]="${_UPO_REWRITE_REASON:--}"
    CSV_FIELDS[20]="${_UPO_REWRITE_LOC:-auto}"
    _UPO_REWRITE_APPLIED="yes"
  fi
  return 0
}

function update_path_option() {
  local domain="${1:-}" listen_port="${2:-}" path_prefix="${3:-}"
  shift 3 || true

  if [ -z "$domain" ] || [ -z "$listen_port" ] || [ -z "$path_prefix" ]; then
    echo "[Usage] update-path-option <domain> <nginx_port> <path_prefix> [--new-path prefix] [--nginx-port port] [--ws yes|no|inherit] [--redirect inherit|off|301|302|308] [--headers name|none] [--match prefix|exact|regex] [--priority int] [--target port|host:port|none] [--rewrite none|strip-prefix|replace:/path] [--reason text] [--loc text]"
    exit 1
  fi

  ensure_valid_or_prompt domain "$domain" "domain" "" is_valid_domain
  ensure_valid_or_prompt listen_port "$listen_port" "nginx_port" "" is_valid_port
  ensure_valid_or_prompt path_prefix "$path_prefix" "path" "/" is_valid_path_prefix

  resolve_backend_domain domain "$domain" true

  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Error] No port mappings configured." >&2
    exit 1
  }
  local current_found="no" line="" line_no=0
  local cur_header="" cur_ws="" cur_redirect="" cur_code=""
  local cur_match="prefix" cur_priority="100" cur_target="" cur_rewrite="none" cur_reason="-" cur_loc="auto"
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      echo "[Error] Invalid backend_ports.csv row at line ${line_no}." >&2
      exit 1
    fi
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    if [ "$STATE_BP_RECORD_TYPE" = "path" ] &&
      [ "$STATE_BP_DOMAIN" = "$domain" ] &&
      [ "$STATE_BP_LISTEN_PORT" = "$listen_port" ] &&
      [ "$STATE_BP_PATH_PREFIX" = "$path_prefix" ]; then
      cur_header="$STATE_BP_HEADER_SET"
      cur_ws="$STATE_BP_WS"
      cur_redirect="$STATE_BP_REDIRECT_FLAG"
      cur_code="$STATE_BP_REDIRECT_CODE"
      cur_match="${STATE_BP_PATH_MATCH:-prefix}"
      cur_priority="${STATE_BP_PATH_PRIORITY:-100}"
      cur_target="${STATE_BP_PATH_TARGET:-}"
      cur_rewrite="${STATE_BP_PATH_REWRITE:-none}"
      cur_reason="${STATE_BP_REASON:--}"
      cur_loc="${STATE_BP_LOC:-auto}"
      current_found="yes"
      break
    fi
  done <"$BACKEND_PORTS_FILE"
  [ "$current_found" = "yes" ] || {
    echo "[Error] Path override for $domain on port $listen_port at '$path_prefix' not found." >&2
    exit 1
  }

  local new_path="$path_prefix" new_listen="$listen_port" ws_opt="" redirect_opt="" header_set_opt=""
  local match_opt="" priority_opt="" target_opt="" rewrite_opt="" reason_opt="" loc_opt=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --new-path)
      require_option_value "$@" || exit 1
      new_path="${2:-}"
      shift 2
      ;;
    --nginx-port)
      require_option_value "$@" || exit 1
      new_listen="${2:-}"
      shift 2
      ;;
    --ws)
      require_option_value "$@" || exit 1
      ws_opt="${2:-}"
      shift 2
      ;;
    --redirect)
      require_option_value "$@" || exit 1
      redirect_opt="${2:-}"
      shift 2
      ;;
    --headers)
      require_option_value "$@" || exit 1
      header_set_opt="${2:-}"
      shift 2
      ;;
    --match)
      require_option_value "$@" || exit 1
      match_opt="${2:-}"
      shift 2
      ;;
    --priority)
      require_option_value "$@" || exit 1
      priority_opt="${2:-}"
      shift 2
      ;;
    --target)
      require_option_value "$@" || exit 1
      target_opt="${2:-}"
      shift 2
      ;;
    --rewrite)
      require_option_value "$@" || exit 1
      rewrite_opt="${2:-}"
      shift 2
      ;;
    --reason)
      require_option_value "$@" || exit 1
      reason_opt="${2:-}"
      shift 2
      ;;
    --loc)
      require_option_value "$@" || exit 1
      loc_opt="${2:-}"
      shift 2
      ;;
    *)
      echo "[Usage] update-path-option <domain> <nginx_port> <path_prefix> [--new-path prefix] [--nginx-port port] [--ws yes|no|inherit] [--redirect inherit|off|301|302|308] [--headers name|none] [--match prefix|exact|regex] [--priority int] [--target port|host:port|none] [--rewrite none|strip-prefix|replace:/path] [--reason text] [--loc text]"
      exit 1
      ;;
    esac
  done

  ensure_valid_or_prompt new_listen "$new_listen" "nginx_port" "$listen_port" is_valid_port
  ensure_valid_or_prompt new_path "$new_path" "path" "$path_prefix" is_valid_path_prefix
  _require_port_mapping_for_path "$domain" "$new_listen" || exit 1

  local ws_store redirect_flag redirect_code header_store
  local match_store priority_store target_store rewrite_store reason_store loc_store
  if [ -n "$ws_opt" ]; then
    _parse_path_ws "$ws_opt" || exit 1
    ws_store="$PATH_WS_FLAG"
  else
    ws_store="$cur_ws"
  fi

  if [ -n "$redirect_opt" ]; then
    _parse_path_redirect "$redirect_opt" || exit 1
    redirect_flag="$PATH_REDIRECT_FLAG"
    redirect_code="$PATH_REDIRECT_CODE"
  else
    redirect_flag="$cur_redirect"
    redirect_code="$cur_code"
  fi

  if [ -n "$header_set_opt" ]; then
    if [ "$header_set_opt" = "none" ]; then
      header_store=""
    else
      if ! is_valid_header_set_name "$header_set_opt"; then
        echo "[Error] Header set name must use letters, numbers, underscores, or dashes." >&2
        exit 1
      fi
      header_store="$header_set_opt"
    fi
  else
    header_store="$cur_header"
  fi

  if [ -n "$match_opt" ]; then
    _parse_path_match_mode "$match_opt" || exit 1
    match_store="$PATH_MATCH_MODE"
  else
    match_store="$cur_match"
  fi

  if [ -n "$priority_opt" ]; then
    _parse_path_priority "$priority_opt" || exit 1
    priority_store="$PATH_PRIORITY"
  else
    priority_store="$cur_priority"
  fi

  if [ -n "$target_opt" ]; then
    if [ "$target_opt" = "none" ]; then
      target_store=""
    else
      _parse_path_target "$target_opt" || exit 1
      target_store="$PATH_TARGET"
    fi
  else
    target_store="$cur_target"
  fi

  if [ -n "$rewrite_opt" ]; then
    _parse_path_rewrite "$rewrite_opt" || exit 1
    rewrite_store="$PATH_REWRITE"
  else
    rewrite_store="$cur_rewrite"
  fi

  if [ -n "$reason_opt" ]; then
    _parse_path_reason "$reason_opt" || exit 1
    reason_store="$PATH_REASON"
  else
    reason_store="$cur_reason"
  fi

  if [ -n "$loc_opt" ]; then
    _parse_path_loc "$loc_opt" || exit 1
    loc_store="$PATH_LOC"
  else
    loc_store="$cur_loc"
  fi

  local duplicate_found="no"
  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      echo "[Error] Invalid backend_ports.csv row at line ${line_no}." >&2
      exit 1
    fi
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    if [ "$STATE_BP_RECORD_TYPE" = "path" ] &&
      [ "$STATE_BP_DOMAIN" = "$domain" ] &&
      [ "$STATE_BP_LISTEN_PORT" = "$new_listen" ] &&
      [ "$STATE_BP_PATH_PREFIX" = "$new_path" ]; then
      if [ "$STATE_BP_LISTEN_PORT" != "$listen_port" ] || [ "$STATE_BP_PATH_PREFIX" != "$path_prefix" ]; then
        duplicate_found="yes"
        break
      fi
    fi
  done <"$BACKEND_PORTS_FILE"
  if [ "$duplicate_found" = "yes" ]; then
    echo "[Error] Path override for $domain on port $new_listen at '$new_path' already exists." >&2
    exit 1
  fi

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "update_path_${domain}_${listen_port}_to_${new_listen}_$(_sanitize_path_for_id "$new_path")"; then
    exit 1
  fi
  _UPO_REWRITE_DOMAIN="$domain"
  _UPO_REWRITE_OLD_PATH="$path_prefix"
  _UPO_REWRITE_OLD_PORT="$listen_port"
  _UPO_REWRITE_NEW_PATH="$new_path"
  _UPO_REWRITE_NEW_PORT="$new_listen"
  _UPO_REWRITE_HEADER="$header_store"
  _UPO_REWRITE_WS="$ws_store"
  _UPO_REWRITE_REDIRECT="$redirect_flag"
  _UPO_REWRITE_CODE="$redirect_code"
  _UPO_REWRITE_MATCH="$match_store"
  _UPO_REWRITE_PRIORITY="$priority_store"
  _UPO_REWRITE_TARGET="$target_store"
  _UPO_REWRITE_REWRITE="$rewrite_store"
  _UPO_REWRITE_REASON="$reason_store"
  _UPO_REWRITE_LOC="$loc_store"
  _UPO_REWRITE_APPLIED="no"
  if ! csv_rewrite_rows "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" _update_path_option_rewrite_row_cb; then
    return 1
  fi
  if [ "$_UPO_REWRITE_APPLIED" != "yes" ]; then
    echo "[Error] Path override for $domain on port $listen_port at '$path_prefix' not found." >&2
    return 1
  fi

  local path_id path_label
  path_id=$(_sanitize_path_for_id "$new_path")
  path_label="$domain:$new_listen$new_path"
  echo "[Info] Updated path override $path_label."
  log_msg "Updated path override ${path_label}"
  create_backup "" "UpdatePath_${domain}_${new_listen}_${path_id}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
