# shellcheck shell=bash

function set_port_tls_ciphers() {
  if [ "$#" -lt 1 ]; then
    echo "[Usage] set-port-tls-ciphers <port> <cipher string>"
    return 1
  fi
  local port="${1:-}"
  shift
  local ciphers="$*"
  if [ -z "$port" ] || [ -z "$ciphers" ]; then
    echo "[Usage] set-port-tls-ciphers <port> <cipher string>"
    return 1
  fi
  require_valid_port "$port" 1 || return 1
  _validate_tls_ciphers "$ciphers" || return 1
  if ! _require_https_port_mapping "$port"; then
    return 1
  fi
  mkdir -p "$(dirname "$PORT_TLS_CIPHERS_FILE")" || return 1
  begin_transaction_return "set_port_tls_ciphers_$port" "$CONFIG_DIR" || return 1
  state_csv_upsert_two_col_value "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" "$port" "$ciphers" || { transaction_return_failure; return 1; }
  echo "[Info] Set TLS ciphers for port $port"
  update_nginx_config || { transaction_return_failure; return 1; }
  end_transaction_success || { transaction_return_failure; return 1; }
}
