# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function _disable_all_security_ip_rules_rewrite_row() {
  CSV_FIELDS[0]="0"
  return 0
}

function disable_all_security_ip_rules() {
  if [ ! -f "$SECURITY_IP_RULES_DB" ] || [ ! -s "$SECURITY_IP_RULES_DB" ]; then
    echo "[Info] No security IP rules configured."
    return
  fi
  if [ "$(csv_data_row_count "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER" 2>/dev/null || echo 0)" -eq 0 ]; then
    echo "[Info] No security IP rules configured."
    return
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "disable_all_security_ip_rules"; then
    exit 1
  fi
  csv_rewrite_rows "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER" "$STATE_SECURITY_IP_RULES_COLS" _disable_all_security_ip_rules_rewrite_row || return 1
  echo "[Info] Disabled all security IP rules."
  create_backup "" "DisableAllSecIP"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
