# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function set_security_rule_mode() {
  local id="${1:-}" mode="${2:-}"
  if ! [[ "$id" =~ ^[0-9]+$ && ("$mode" = and || "$mode" = or) ]]; then
    echo "[Usage] set-security-rule-mode <id> <and|or>"
    exit 1
  fi
  [ -f "$SECURITY_RULES_DB" ] || {
    echo "[Error] No security rules" >&2
    exit 1
  }
  local cur=$(_sr_load_line "$id")
  [ -n "$cur" ] || {
    echo "[Error] Not found" >&2
    exit 1
  }
  if ! csv_parse_line "$cur" || [ "$CSV_FIELD_COUNT" -ne "$STATE_SECURITY_RULES_COLS" ]; then
    echo "[Error] Corrupt security rule row for id $id" >&2
    exit 1
  fi

  local e d m c n newline
  e="${CSV_FIELDS[0]}"
  d="${CSV_FIELDS[1]}"
  m="${CSV_FIELDS[2]}"
  c="${CSV_FIELDS[3]}"
  n="${CSV_FIELDS[4]}"

  if ! [[ "$n" =~ ^(10|[2-9])$ ]]; then
    echo "[Error] Rule $id has a single condition; mode not applicable" >&2
    exit 1
  fi

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "set_security_rule_mode_${id}_${mode}"; then
    exit 1
  fi
  CSV_FIELDS[2]="$mode"
  newline="$(csv_join_row "${CSV_FIELDS[@]}")"
  _sr_replace_line "$id" "$newline"
  echo "[Info] Set rule $id mode to $mode"
  create_backup "" "SetSecRuleMode_${id}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}

# Backend security rule status overrides (unchanged)
