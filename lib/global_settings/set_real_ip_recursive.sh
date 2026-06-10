# shellcheck shell=bash

# Toggle real_ip_recursive behavior
function set_real_ip_recursive() {
  local val="${1:-}"
  if [[ "$val" != "on" && "$val" != "off" ]]; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-real-ip-recursive <on|off>" >&2
    return 1
  fi
  local started_txn=false
  _config_begin_return_transaction_if_needed started_txn "set_real_ip_recursive_${val}" || return 1
  REAL_IP_RECURSIVE="$val"
  save_config || { transaction_return_failure; return 1; }
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} REAL_IP_RECURSIVE set to $val and saved in $GLOBAL_SETTINGS_FILE."
  update_nginx_config || { transaction_return_failure; return 1; }
  _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
}
