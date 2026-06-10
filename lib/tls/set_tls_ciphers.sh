# shellcheck shell=bash

function set_tls_ciphers() {
  local ciphers="$*"
  [ -z "$ciphers" ] && {
    echo "[Usage] set-tls-ciphers <cipher_string>" >&2
    return 1
  }
  _validate_tls_ciphers "$ciphers" || return 1
  begin_transaction_return "set_tls_ciphers" "$CONFIG_DIR" || return 1
  TLS_CIPHERS="$ciphers"
  save_config || { transaction_return_failure; return 1; }
  echo "[Info] TLS ciphers set to $ciphers"
  update_nginx_config || { transaction_return_failure; return 1; }
  end_transaction_success || { transaction_return_failure; return 1; }
}
