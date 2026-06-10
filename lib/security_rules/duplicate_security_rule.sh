# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function duplicate_security_rule() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]+$ ]] || {
    echo "[Usage] duplicate-security-rule <id>"
    exit 1
  }
  [ -f "$SECURITY_RULES_DB" ] || {
    echo "[Error] No security rules" >&2
    exit 1
  }
  local cur=$(_sr_load_line "$id")
  [ -n "$cur" ] || {
    echo "[Error] Rule $id not found" >&2
    exit 1
  }
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "duplicate_security_rule_${id}"; then
    exit 1
  fi
  _sr_ensure_rules_db || exit 1
  echo "$cur" >>"$SECURITY_RULES_DB"
  local new_id
  new_id="$(csv_data_row_count "$SECURITY_RULES_DB" "$STATE_SECURITY_RULES_HEADER" 2>/dev/null || echo 1)"
  echo "[Info] Duplicated rule $id as #$new_id"
  create_backup "" "DuplicateSecRule_${id}_to_${new_id}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
