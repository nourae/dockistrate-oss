# shellcheck shell=bash

function set_tls_protocols() {
  local protocols="$*"
  [ -z "$protocols" ] && {
    echo "[Usage] set-tls-protocols <protocols>" >&2
    return 1
  }
  _validate_tls_protocol_string_for_render "$protocols" "TLS protocols" 0 || return 1
  begin_transaction_return "set_tls_protocols" "$CONFIG_DIR" || return 1
  TLS_PROTOCOLS="$protocols"
  save_config || { transaction_return_failure; return 1; }
  echo "[Info] TLS protocols set to $protocols"
  update_nginx_config || { transaction_return_failure; return 1; }
  end_transaction_success || { transaction_return_failure; return 1; }
}
