# shellcheck shell=bash

function add_path_option() {
  local domain="${1:-}" listen_port="${2:-}" path_prefix="${3:-}"
  shift 3 || true

  if [ -z "$domain" ] || [ -z "$listen_port" ] || [ -z "$path_prefix" ]; then
    echo "[Usage] add-path-option <domain> <nginx_port> <path_prefix> [--ws yes|no|inherit] [--redirect inherit|off|301|302|308] [--headers name|none] [--match prefix|exact|regex] [--priority int] [--target port|host:port] [--rewrite none|strip-prefix|replace:/path] [--reason text] [--loc text]"
    exit 1
  fi

  ensure_valid_or_prompt domain "$domain" "domain" "" is_valid_domain
  ensure_valid_or_prompt listen_port "$listen_port" "nginx_port" "" is_valid_port
  ensure_valid_or_prompt path_prefix "$path_prefix" "path" "/" is_valid_path_prefix

  resolve_backend_domain domain "$domain" true
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "add_path_${domain}_${listen_port}_$(_sanitize_path_for_id "$path_prefix")"; then
    exit 1
  fi

  if ! state_csv_require_file "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
    echo "[Error] Failed to initialize backend state file: $BACKEND_PORTS_FILE" >&2
    exit 1
  fi

  [ -f "$BACKEND_PORTS_FILE" ] || {
    echo "[Error] No port mappings configured." >&2
    exit 1
  }
  _require_port_mapping_for_path "$domain" "$listen_port" || exit 1

  local ws_opt="inherit" redirect_opt="inherit" header_set=""
  local match_opt="prefix" priority_opt="100" target_opt="" rewrite_opt="none" reason_opt="-" loc_opt="auto"
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --ws)
      require_option_value "$@" || exit 1
      ws_opt="${2:-inherit}"
      shift 2
      ;;
    --redirect)
      require_option_value "$@" || exit 1
      redirect_opt="${2:-inherit}"
      shift 2
      ;;
    --headers)
      require_option_value "$@" || exit 1
      header_set="${2:-}"
      shift 2
      ;;
    --match)
      require_option_value "$@" || exit 1
      match_opt="${2:-prefix}"
      shift 2
      ;;
    --priority)
      require_option_value "$@" || exit 1
      priority_opt="${2:-100}"
      shift 2
      ;;
    --target)
      require_option_value "$@" || exit 1
      target_opt="${2:-}"
      shift 2
      ;;
    --rewrite)
      require_option_value "$@" || exit 1
      rewrite_opt="${2:-none}"
      shift 2
      ;;
    --reason)
      require_option_value "$@" || exit 1
      reason_opt="${2:--}"
      shift 2
      ;;
    --loc)
      require_option_value "$@" || exit 1
      loc_opt="${2:-auto}"
      shift 2
      ;;
    *)
      echo "[Usage] add-path-option <domain> <nginx_port> <path_prefix> [--ws yes|no|inherit] [--redirect inherit|off|301|302|308] [--headers name|none] [--match prefix|exact|regex] [--priority int] [--target port|host:port] [--rewrite none|strip-prefix|replace:/path] [--reason text] [--loc text]"
      exit 1
      ;;
    esac
  done

  _parse_path_ws "$ws_opt" || exit 1
  local ws_store="$PATH_WS_FLAG"

  _parse_path_redirect "$redirect_opt" || exit 1
  local redirect_flag="$PATH_REDIRECT_FLAG" redirect_code="$PATH_REDIRECT_CODE"
  _parse_path_match_mode "$match_opt" || exit 1
  _parse_path_priority "$priority_opt" || exit 1
  _parse_path_target "$target_opt" || exit 1
  _parse_path_rewrite "$rewrite_opt" || exit 1
  _parse_path_reason "$reason_opt" || exit 1
  _parse_path_loc "$loc_opt" || exit 1

  if [ -n "$header_set" ]; then
    if [ "$header_set" = "none" ]; then
      header_set=""
    else
      if ! is_valid_header_set_name "$header_set"; then
        echo "[Error] Header set name must use letters, numbers, underscores, or dashes." >&2
        exit 1
      fi
    fi
  fi

  if awk -F',' -v d="$domain" -v p="$listen_port" -v path="$path_prefix" '
    BEGIN { found = 0 }
    $1=="path" && $2==d && $7==p && $5==path { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$BACKEND_PORTS_FILE"; then
    echo "[Error] Path override for $domain on port $listen_port at '$path_prefix' already exists." >&2
    exit 1
  fi

  state_backend_ports_row_path "$domain" "$path_prefix" "$header_set" "$listen_port" "$ws_store" "$redirect_flag" "$redirect_code" "$PATH_MATCH_MODE" "$PATH_PRIORITY" "$PATH_TARGET" "$PATH_REWRITE" "$PATH_REASON" "$PATH_LOC" >>"$BACKEND_PORTS_FILE"
  local path_id
  path_id=$(_sanitize_path_for_id "$path_prefix")
  echo "[Info] Added path override ${domain}:${listen_port} ${path_prefix}."
  log_msg "Added path override ${domain}:${listen_port}${path_prefix}"
  create_backup "" "AddPath_${domain}_${listen_port}_${path_id}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
