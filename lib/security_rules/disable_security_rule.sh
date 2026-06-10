# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function disable_security_rule() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]+$ ]] || {
    echo "[Usage] disable-security-rule <id>"
    exit 1
  }
  local line=$(_sr_load_line "$id")
  [ -n "$line" ] || {
    echo "[Error] Not found" >&2
    exit 1
  }
  if ! csv_parse_line "$line" || [ "$CSV_FIELD_COUNT" -ne "$STATE_SECURITY_RULES_COLS" ]; then
    echo "[Error] Malformed rule entry" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "disable_security_rule_${id}"; then
    exit 1
  fi
  CSV_FIELDS[0]="0"
  _sr_replace_line "$id" "$(csv_join_row "${CSV_FIELDS[@]}")"
  echo "[Info] Disabled rule $id"
  create_backup "" "DisableSecRule_${id}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
