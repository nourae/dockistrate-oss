# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function disable_security_ip_rule() {
  local id="${1:-}"
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "[Usage] disable-security-ip <id>"
    exit 1
  fi
  [ -f "$SECURITY_IP_RULES_DB" ] || {
    echo "[Error] No security IP rules to disable." >&2
    exit 1
  }
  local line
  line="$(_sr_ip_load_line "$id" || true)"
  [ -n "$line" ] || {
    echo "[Error] Rule $id not found" >&2
    exit 1
  }
  if ! csv_parse_line "$line" || [ "$CSV_FIELD_COUNT" -ne "$STATE_SECURITY_IP_RULES_COLS" ]; then
    echo "[Error] Rule $id is malformed" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "disable_security_ip_${id}"; then
    exit 1
  fi
  CSV_FIELDS[0]="0"
  _sr_ip_replace_line "$id" "$(csv_join_row "${CSV_FIELDS[@]}")"
  echo "[Info] Disabled security IP rule $id"
  create_backup "" "DisableSecIP_${id}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
