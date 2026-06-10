# shellcheck shell=bash

function set_proxy_ip_header() {
  local name="${1:-}"
  local new_proxy_ip_header="" message=""
  [ -z "$name" ] && {
    echo "[Usage] set-proxy-ip-header <header|off>" >&2
    return 1
  }

  if [ "$name" = "off" ]; then
    message="[Info] Proxy IP header disabled globally"
  else
    if ! is_valid_header_name "$name"; then
      echo "[Error] Invalid header name: $name" >&2
      return 1
    fi
    new_proxy_ip_header="$name"
    message="[Info] Proxy IP header set globally to $name"
  fi

  local started_txn=false
  _config_begin_return_transaction_if_needed started_txn "set_proxy_ip_header" || return 1
  PROXY_IP_HEADER="$new_proxy_ip_header"
  save_config || { transaction_return_failure; return 1; }
  echo "$message"
  update_nginx_config || { transaction_return_failure; return 1; }
  _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
}
