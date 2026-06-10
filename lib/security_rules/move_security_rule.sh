# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function move_security_rule() {
  local from="${1:-}" to="${2:-}"
  [[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ ]] || {
    echo "[Usage] move-security-rule <from> <to>"
    exit 1
  }
  [ -f "$SECURITY_RULES_DB" ] || {
    echo "[Error] No security rules" >&2
    exit 1
  }
  _sr_ensure_rules_db || exit 1
  local count
  count="$(csv_data_row_count "$SECURITY_RULES_DB" "$STATE_SECURITY_RULES_HEADER" 2>/dev/null || echo 0)"
  if [ "$count" -lt 1 ]; then
    echo "[Error] No security rules" >&2
    exit 1
  fi
  if [ "$from" -lt 1 ] || [ "$from" -gt "$count" ] || [ "$to" -lt 1 ] || [ "$to" -gt "$count" ]; then
    echo "[Error] Rule index out of range (1-${count})" >&2
    exit 1
  fi

  local -a rows=()
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    rows+=("$line")
  done <"$SECURITY_RULES_DB"

  local from_idx=$((from - 1))
  local to_idx=$((to - 1))
  local moving="${rows[$from_idx]}"
  unset "rows[$from_idx]"
  rows=("${rows[@]}")

  local -a reordered=()
  local i=0 inserted=0
  for ((i = 0; i < ${#rows[@]}; i++)); do
    if [ "$i" -eq "$to_idx" ]; then
      reordered+=("$moving")
      inserted=1
    fi
    reordered+=("${rows[$i]}")
  done
  if [ "$inserted" -eq 0 ]; then
    reordered+=("$moving")
  fi

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "move_security_rule_${from}_to_${to}"; then
    exit 1
  fi
  local tmp_file=""
  make_temp_for_file tmp_file "$SECURITY_RULES_DB" || return 1
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"$tmp_file"
  for line in "${reordered[@]}"; do
    printf '%s\n' "$line" >>"$tmp_file"
  done
  finalize_temp_file "$SECURITY_RULES_DB" "$tmp_file"

  echo "[Info] Moved rule $from -> $to"
  create_backup "" "MoveSecRule_${from}_to_${to}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}

# Update: change field(s) and/or replace conditions
