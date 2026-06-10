# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function list_security_ip() {
  if [ ! -f "$SECURITY_IP_RULES_DB" ] || [ ! -s "$SECURITY_IP_RULES_DB" ]; then
    echo "[Info] No security IP rules configured."
    return
  fi
  if ! csv_require_header "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER"; then
    echo "[Info] No security IP rules configured."
    return
  fi
  local n=1 line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || continue
    local enabled domain scope action ip code disabled=""
    enabled="${CSV_FIELDS[0]}"
    domain="${CSV_FIELDS[1]}"
    scope="${CSV_FIELDS[2]}"
    action="${CSV_FIELDS[3]}"
    ip="${CSV_FIELDS[4]}"
    code="${CSV_FIELDS[5]}"
    [ -z "$domain" ] && continue
    [ "$enabled" = "1" ] || disabled=" [disabled]"
    printf "%d: %s %s %s %s%s\n" "$n" "$domain" "$scope" "$action" "$ip" "$disabled"
    n=$((n + 1))
  done <"$SECURITY_IP_RULES_DB"
}
