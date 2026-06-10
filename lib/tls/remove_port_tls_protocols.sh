# shellcheck shell=bash

function remove_port_tls_protocols() {
  local port="${1:-}"
  [ -z "$port" ] && {
    echo "[Usage] remove-port-tls-protocols <port>"
    return 1
  }
  require_valid_port "$port" 1 || return 1
  if [ -f "$PORT_TLS_PROTOCOLS_FILE" ]; then
    local started_txn=false
    if ! transaction_is_active; then
      if ! begin_transaction "remove_port_tls_protocols_$port" "$CONFIG_DIR"; then
        return 1
      fi
      started_txn=true
    fi
    state_csv_delete_two_col_key "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" "$port"
    echo "[Info] Removed TLS protocol override for port $port"
    update_nginx_config
    if [ "$started_txn" = true ]; then
      end_transaction_success
    fi
  fi
}
