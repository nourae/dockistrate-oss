# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function set_acl_policy() {
  local policy="${1:-}"
  if [[ "$policy" != "allow" && "$policy" != "deny" ]]; then
    echo "[Usage] set-acl-policy <allow|deny>" >&2
    return 1
  fi

  if [ "$policy" = "deny" ]; then
    _sr_validate_acl_cidr_mode_all_domains "$policy" "${ACL_STATUS:-403}" || return 1
  fi

  local started_txn=false
  _config_begin_return_transaction_if_needed started_txn "set_acl_policy_${policy}" || return 1
  ACL_POLICY="$policy"
  save_config || { transaction_return_failure; return 1; }
  echo "[Info] ACL_POLICY set to $policy"
  update_nginx_config_for_security_change || { transaction_return_failure; return 1; }
  _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
}
