# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function list_security_rules() {
  local filter_domain="${1:-}"
  [ -n "$filter_domain" ] && filter_domain="$(normalize_domain "$filter_domain")"
  if [ ! -f "$SECURITY_RULES_DB" ]; then
    echo "[Info] No security rules configured."
    return 0
  fi
  if ! csv_require_header "$SECURITY_RULES_DB" "$STATE_SECURITY_RULES_HEADER"; then
    return 1
  fi

  local line="" line_no=0 rid=0 printed=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid persisted security rule row in ${SECURITY_RULES_DB} at line ${line_no}: ${CSV_PARSE_ERROR:-parse error}" >&2
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_SECURITY_RULES_COLS" ]; then
      echo "[Error] Invalid persisted security rule column count in ${SECURITY_RULES_DB} at line ${line_no}: expected ${STATE_SECURITY_RULES_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    rid=$((rid + 1))

    local e d m c n reason loc
    e="${CSV_FIELDS[0]}"
    d="${CSV_FIELDS[1]}"
    m="${CSV_FIELDS[2]}"
    c="${CSV_FIELDS[3]}"
    n="${CSV_FIELDS[4]}"
    reason="${CSV_FIELDS[45]:--}"
    loc="${CSV_FIELDS[46]:-auto}"
    [[ -n "$filter_domain" && "$d" != "$filter_domain" ]] && continue

    printed=1
    # Bash 3 compatibility: avoid ${var^^}
    local head="$m"
    head="$(printf '%s' "$head" | tr '[:lower:]' '[:upper:]')"
    ((n == 1)) && head="SINGLE"
    local disabled=""
    [[ "$e" != "1" ]] && disabled=" [disabled]"
    if ((n == 1)); then
      printf "%d: %s %s (n=%s) status=%s reason=%s loc=%s%s\n" "$rid" "$head" "$d" "$n" "${c:--}" "$reason" "$loc" "$disabled"
    else
      printf "%d: %s %s (n=%s, mode=%s) status=%s reason=%s loc=%s%s\n" "$rid" "$head" "$d" "$n" "$head" "${c:--}" "$reason" "$loc" "$disabled"
    fi
    local idx base
    for idx in {0..9}; do
      base=$((5 + (idx * 4)))
      local _s _n _c _v
      _s="${CSV_FIELDS[$base]}"
      [[ -z "$_s" ]] && continue
      _n="${CSV_FIELDS[$((base + 1))]}"
      _c="${CSV_FIELDS[$((base + 2))]}"
      _v="${CSV_FIELDS[$((base + 3))]}"
      printf "  %d. %s%s %s %s\n" "$((idx + 1))" "$_s" "$([[ -n "$_n" && "$_n" != "-" ]] && echo ":$_n")" "$_c" "${_v:--}"
    done
  done <"$SECURITY_RULES_DB"

  if ((printed == 0)); then
    echo "[Info] No security rules configured."
  fi
  return 0
}
