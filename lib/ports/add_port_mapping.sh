# shellcheck shell=bash

function add_port_mapping() {
  local domain="${1:-}"
  local custom_port="${2:-}"
  local upstream_port="${3:-}"
  local protocol="${4:-}" # http|https|tcp|udp
  local cert_dir="${5:-}" # path or "none"
  local ws="${6:-}"       # yes|no
  local http3_opt="off" alt_svc_opt="auto"
  local http3_value="off" alt_svc_value="auto"
  if [ $# -gt 6 ]; then
    shift 6
  else
    shift $#
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
    --http3)
      require_option_value "$@" || exit 1
      http3_opt="${2:-off}"
      shift 2
      ;;
    --alt-svc)
      require_option_value "$@" || exit 1
      alt_svc_opt="${2:-auto}"
      shift 2
      ;;
    *)
      echo "[Error] Unknown option: $1" >&2
      echo "[Usage] add-port <domain> <nginx_port> <container_port> <http|https|tcp|udp> <cert_path|none> [yes|no ws] [--http3 on|off] [--alt-svc auto|off|custom]" >&2
      exit 1
      ;;
    esac
  done

  if [ -z "$domain" ] || [ -z "$custom_port" ] || [ -z "$upstream_port" ] || [ -z "$protocol" ]; then
    echo "[Usage] add-port <domain> <nginx_port> <container_port> <http|https|tcp|udp> <cert_path|none> [yes|no ws] [--http3 on|off] [--alt-svc auto|off|custom]"
    exit 1
  fi

  # Validate inputs; re-prompt when interactive
  ensure_valid_or_prompt domain "$domain" "domain" "" is_valid_domain
  local provided_domain="$domain"
  resolve_backend_domain domain "$domain" true
  if ! backend_exists "$domain"; then
    echo "[Error] Backend domain '$provided_domain' not found. Create it first." >&2
    exit 1
  fi
  ensure_valid_or_prompt custom_port "$custom_port" "nginx_port" "" is_valid_port
  ensure_valid_or_prompt upstream_port "$upstream_port" "container_port" "" is_valid_port
  ensure_valid_or_prompt protocol "$protocol" "protocol" "" is_valid_protocol
  if ! validate_http_port_combination "$protocol" "$custom_port"; then
    exit 1
  fi

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "add_port_${domain}_${custom_port}" "$CERTS_DIR"; then
    exit 1
  fi

  if ! state_csv_require_file "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
    echo "[Error] Failed to initialize backend state file: $BACKEND_PORTS_FILE" >&2
    exit 1
  fi

  # Prevent duplicate entries for the same domain and port
  if [ -f "$BACKEND_PORTS_FILE" ] &&
    awk -F',' -v d="$domain" -v p="$custom_port" '
       ($1=="port" && $2==d && $7==p) {
         found=1
         exit
       }
       END { exit(found ? 0 : 1) }
     ' "$BACKEND_PORTS_FILE"; then
    echo "[Info] Port mapping for $domain on port $custom_port already exists. Skipping."
    _config_end_transaction_if_started "$started_txn"
    return 0
  fi

  if [ "$protocol" = "https" ]; then
    _parse_http3_flag "$http3_opt" || exit 1
    _parse_alt_svc_mode "$alt_svc_opt" || exit 1
    http3_value="$PORT_HTTP3_FLAG"
    alt_svc_value="$PORT_ALT_SVC_MODE"
  else
    http3_value="off"
    alt_svc_value="auto"
  fi

  local host_transport="tcp"
  [ "$protocol" = "udp" ] && host_transport="udp"
  if ! assert_host_port_available_or_fail "$custom_port" "$host_transport"; then
    exit 1
  fi

  if [ "$protocol" = "https" ] && [ "$http3_value" = "on" ]; then
    if _udp_mapping_listen_in_use "$custom_port"; then
      echo "[Error] UDP port ${custom_port} is already in use by another mapping." >&2
      exit 1
    fi
    if ! assert_host_port_available_or_fail "$custom_port" "udp"; then
      exit 1
    fi
  fi

  if [ "$protocol" == "https" ]; then
    if [ "$cert_dir" == "none" ] || [ -z "$cert_dir" ]; then
      if declare -F add_cert >/dev/null 2>&1; then
        echo "[Info] No certificate provided; generating self-signed cert for ${domain}:${custom_port}."
        local prev_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
        push_skip_update_nginx_config prev_skip_update
        CERT_AUTOCONFIG_DISABLED=1 add_cert "$domain" "$custom_port" selfsigned
        pop_skip_update_nginx_config "$prev_skip_update"
        cert_dir="selfsigned/live/${domain}_${custom_port}"
      else
        echo "[Error] HTTPS selected but no cert provided and certificate helper unavailable." >&2
        exit 1
      fi
    fi
    # Accept paths starting with 'certs/' and normalize
    local abs_cert_dir
    if ! normalize_cert_dir abs_cert_dir "$cert_dir"; then
      exit 1
    fi
    if [ ! -d "$abs_cert_dir" ]; then
      echo "[Error] Cert directory '$cert_dir' not found." >&2
      exit 1
    fi
    local stored_cert_dir
    relativize_cert_dir stored_cert_dir "$abs_cert_dir"
    cert_dir="$stored_cert_dir"
  fi
  if [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; then
    cert_dir=""
    ws="no"
    if _stream_listen_in_use "$custom_port" "$protocol"; then
      local protocol_upper
      protocol_upper="$(printf '%s' "$protocol" | tr '[:lower:]' '[:upper:]')"
      echo "[Error] ${protocol_upper} port ${custom_port} is already in use by another mapping." >&2
      exit 1
    fi
  else
    [ -z "$ws" ] && ws="no"
    ensure_valid_or_prompt ws "$ws" "ws" "no" is_yes_no
  fi

  if [ "$protocol" = "http" ] && [ -z "$cert_dir" ]; then
    cert_dir="none"
  fi

  state_backend_ports_row_port "${domain}" "${custom_port}" "${upstream_port}" "${protocol}" "${cert_dir}" "${ws}" "off" "" "$http3_value" "$alt_svc_value" >>"$BACKEND_PORTS_FILE"
  echo "[Info] Added port mapping: domain=$domain => port $custom_port (proto=$protocol)."
  log_msg "Added port mapping $domain:$custom_port -> $upstream_port proto=$protocol http3=$http3_value alt_svc=$alt_svc_value"

  create_backup "" "AddPort_${domain}_${custom_port}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
