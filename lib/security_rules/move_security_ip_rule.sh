# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function move_security_ip_rule() {
  local from="${1:-}" to="${2:-}"
  [[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ ]] || {
    echo "[Usage] move-security-ip-rule <from> <to>"
    exit 1
  }
  [ -f "$SECURITY_IP_RULES_DB" ] || {
    echo "[Error] No security IP rules" >&2
    exit 1
  }
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "move_security_ip_${from}_to_${to}"; then
    exit 1
  fi
  if ! _sr_ip_move_line "$from" "$to"; then
    echo "[Error] Failed to move security IP rule (check indices)." >&2
    exit 1
  fi
  echo "[Info] Moved security IP rule $from -> $to"
  create_backup "" "MoveSecIP_${from}_to_${to}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}

# DB helpers
