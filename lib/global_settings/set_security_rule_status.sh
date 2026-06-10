# shellcheck shell=bash

# Set the HTTP status code returned for security rule violations
function set_security_rule_status() {
  local code="${1:-}"
  if ! is_status_code "$code"; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-security-rule-status <code> (HTTP status code)" >&2
    echo "${GLOBAL_SETTINGS_ERROR_PREFIX} Invalid status code: ${code:-<empty>} (expected 100-599)" >&2
    return 1
  fi
  local started_txn=false
  _config_begin_return_transaction_if_needed started_txn "set_security_rule_status_${code}" || return 1
  SECURITY_RULE_STATUS="$code"
  save_config || { transaction_return_failure; return 1; }
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} SECURITY_RULE_STATUS set to $code and saved in $GLOBAL_SETTINGS_FILE."
  _global_settings_update_nginx_config_for_security_change || { transaction_return_failure; return 1; }
  _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
}
