# shellcheck shell=bash

function set_nginx_directive_strict() {
  local opt="${1:-}"
  if ! is_on_off "$opt"; then
    echo "[Usage] set-nginx-directive-strict <on|off>"
    return 1
  fi

  begin_transaction "set_nginx_directive_strict_${opt}" "$CONFIG_DIR"
  NGINX_DIRECTIVE_STRICT="$opt"
  save_config || _rollback_handler
  if ! update_nginx_config; then
    _rollback_handler
  fi
  end_transaction_success
  echo "[Info] NGINX_DIRECTIVE_STRICT=${opt}"
}
