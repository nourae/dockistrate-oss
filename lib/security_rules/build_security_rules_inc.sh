# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function build_security_rules_inc() {
  local security_rules_inc_dir=""
  SR_RULE_COUNTER=0
  SR_RULE_VARS_EMITTED=""
  security_rules_inc_dir="$(dirname "$SECURITY_RULES_INC")"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$security_rules_inc_dir" "$SECURITY_RULES_INC" || return 1
  fi
  mkdir -p "$security_rules_inc_dir"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$security_rules_inc_dir" "$SECURITY_RULES_INC" || return 1
  fi
  : >"$SECURITY_RULES_INC"
  # Build per-domain IP policy include files first
  build_security_ip_includes || return 1
  [ -f "$SECURITY_RULES_DB" ] || return 0
  csv_require_header "$SECURITY_RULES_DB" "$STATE_SECURITY_RULES_HEADER" || return 1
  local line="" line_no=0 rule_id=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid persisted security rule row in ${SECURITY_RULES_DB} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_SECURITY_RULES_COLS" ]; then
      echo "[Error] Invalid persisted security rule column count in ${SECURITY_RULES_DB} at line ${line_no}: expected ${STATE_SECURITY_RULES_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    rule_id=$((rule_id + 1))

    local enabled domain mode code n reason loc
    enabled="${CSV_FIELDS[0]}"
    domain="${CSV_FIELDS[1]}"
    mode="${CSV_FIELDS[2]}"
    code="${CSV_FIELDS[3]}"
    n="${CSV_FIELDS[4]}"
    reason="${CSV_FIELDS[45]:--}"
    loc="${CSV_FIELDS[46]:-auto}"
    if ! is_valid_reason_value "$reason"; then
      echo "[Error] Invalid persisted security rule reason at line ${line_no} for domain '${domain}'." >&2
      return 1
    fi
    if ! is_valid_loc_value "$loc"; then
      echo "[Error] Invalid persisted security rule source_location at line ${line_no} for domain '${domain}'." >&2
      return 1
    fi

    local eff_code="$code"
    local triplets=() i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      local base=$((5 + ((i - 1) * 4)))
      local _s="${CSV_FIELDS[$base]}"
      [[ -z "$_s" ]] && continue
      local _n="${CSV_FIELDS[$((base + 1))]}"
      local _c="${CSV_FIELDS[$((base + 2))]}"
      local _v="${CSV_FIELDS[$((base + 3))]}"
      local sel
      [[ -z "$_n" || "$_n" == "-" ]] && sel="$(_sr_source_to_selector "$_s")" || sel="$(_sr_source_to_selector "$_s" "$_n")"
      _sr_validate_rule_triplet "$sel" "$_c" "$_v" "Invalid persisted security rule #${rule_id} for domain '${domain}'" || return 1
      triplets+=("$sel" "$_c" "$_v")
    done
    [ "$enabled" = "1" ] || continue
    [[ -z "$eff_code" || "$eff_code" == "-" ]] && eff_code="$(get_backend_security_rule_status "$domain")"
    if ((n == 1)); then
      _generate_security_rule_line "$domain" "${triplets[0]}" "${triplets[1]}" "${triplets[2]}" "$eff_code" "$reason" "$loc" "$line" >>"$SECURITY_RULES_INC"
    else
      _generate_security_rule_multi_line "$mode" "$domain" "$eff_code" "$reason" "$loc" "$line" "${triplets[@]}" >>"$SECURITY_RULES_INC"
    fi
  done <"$SECURITY_RULES_DB"
}

# Build per-domain IP policy includes under $SECURITY_IP_DIR and $SECURITY_IP_STREAM_DIR
