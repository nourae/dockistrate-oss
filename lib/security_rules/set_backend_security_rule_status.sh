# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function set_backend_security_rule_status() {
  local domain="${1:-}"
  local code="${2:-}"
  if [ -z "$domain" ] || ! is_status_code "$code"; then
    echo "[Usage] set-backend-security-rule-status <domain> <code>"
    exit 1
  fi
  domain="$(normalize_domain "$domain")"
  if ! domain_exists "$domain"; then
    echo "[Error] Unknown domain '$domain'" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "set_backend_security_rule_status_${domain}_${code}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$BACKEND_SECURITY_RULE_STATUS_FILE")"
  state_csv_upsert_two_col_value "$BACKEND_SECURITY_RULE_STATUS_FILE" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" "$domain" "$code"
  echo "[Info] Set security rule status for $domain to $code"
  create_backup "" "SetBackendSecRuleStatus_${domain}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
