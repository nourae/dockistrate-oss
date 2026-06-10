# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function set_backend_acl_policy() {
  local domain="${1:-}"
  local policy="${2:-}"
  if [ -z "$domain" ] || [[ "$policy" != "allow" && "$policy" != "deny" ]]; then
    echo "[Usage] set-backend-acl-policy <domain> <allow|deny>"
    exit 1
  fi
  domain="$(normalize_domain "$domain")"
  if ! domain_exists "$domain"; then
    echo "[Error] Unknown domain '$domain'" >&2
    exit 1
  fi

  if [ "$policy" = "deny" ]; then
    _sr_validate_backend_acl_policy_transition "$domain" "$policy" "${ACL_STATUS:-403}" || exit 1
  fi

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "set_backend_acl_policy_${domain}_${policy}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$BACKEND_ACL_POLICY_FILE")"
  state_csv_upsert_two_col_value "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" "$domain" "$policy"
  echo "[Info] Set ACL policy for $domain to $policy"
  create_backup "" "SetBackendACLPolicy_${domain}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
