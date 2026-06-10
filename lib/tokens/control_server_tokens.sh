# shellcheck shell=bash

function control_server_tokens() {
  local opt="${1:-}"
  [ -z "$opt" ] && {
    echo "[Usage] control-server-tokens <on|off>"
    return 1
  }

  case "$opt" in
  on)
    ;;
  off)
    ;;
  *)
    echo "[Usage] control-server-tokens <on|off>"
    return 1
    ;;
  esac

  if ! begin_transaction "control_server_tokens_${opt}" "$CONFIG_DIR"; then
    return 1
  fi
  if ! nginx_directives_set_managed_owned "global" "" "" "" "server_tokens" "$opt"; then
    _rollback_handler
  fi

  local legacy_tokens_conf="${NGINX_HTTP_CONF_DIR}/server_tokens.conf"
  if [ -f "$legacy_tokens_conf" ]; then
    safe_rm_f "$legacy_tokens_conf" "$NGINX_HTTP_CONF_DIR"
  fi

  create_backup "" "ServerTokens_${opt}"
  if ! update_nginx_config; then
    _rollback_handler
  fi
  end_transaction_success
  echo "[Info] server_tokens=${opt}"
}
