# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function remove_backend_acl_status() {
  local domain="${1:-}"
  [ -z "$domain" ] && {
    echo "[Usage] remove-backend-acl-status <domain>"
    exit 1
  }
  domain="$(normalize_domain "$domain")"
  if [ -f "$BACKEND_ACL_STATUS_FILE" ]; then
    local started_txn=false
    if ! _config_begin_transaction_if_needed started_txn "remove_backend_acl_status_${domain}"; then
      exit 1
    fi
    state_csv_delete_two_col_key "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" "$domain"
    echo "[Info] Removed ACL status override for $domain"
    create_backup "" "RemoveBackendACLStatus_${domain}"
    update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
    _config_end_transaction_if_started "$started_txn"
  fi
}
# CRUD for security IP rules
