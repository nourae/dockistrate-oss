# shellcheck shell=bash

function set_port_tls_protocols() {
  if [ "$#" -lt 1 ]; then
    echo "[Usage] set-port-tls-protocols <port> <protocols...>"
    return 1
  fi
  local port="${1:-}"
  shift
  local protocols="$*"
  if [ -z "$port" ] || [ -z "$protocols" ]; then
    echo "[Usage] set-port-tls-protocols <port> <protocols...>"
    return 1
  fi
  require_valid_port "$port" 1 || return 1
  _validate_tls_protocol_string_for_render "$protocols" "TLS protocols for port $port" 0 || return 1
  if ! _require_https_port_mapping "$port"; then
    return 1
  fi
  mkdir -p "$(dirname "$PORT_TLS_PROTOCOLS_FILE")" || return 1
  begin_transaction_return "set_port_tls_protocols_$port" "$CONFIG_DIR" || return 1
  state_csv_upsert_two_col_value "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" "$port" "$protocols" || { transaction_return_failure; return 1; }
  echo "[Info] Set TLS protocols for port $port to $protocols"
  update_nginx_config || { transaction_return_failure; return 1; }
  end_transaction_success || { transaction_return_failure; return 1; }
}
