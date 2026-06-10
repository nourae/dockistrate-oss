# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function update_security_rule() {
  local id="${1:-}"
  shift || true
  [[ "$id" =~ ^[0-9]+$ ]] || {
    echo "[Usage] update-security-rule <id> [--domain d] [--mode and|or] [--code status] [--reason text] [--loc text] [--count n (<src> <name|-> <cond> <value|->)x n]"
    exit 1
  }
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

  local e d m c n r l count_override_provided
  e="${CSV_FIELDS[0]}"
  d="${CSV_FIELDS[1]}"
  m="${CSV_FIELDS[2]}"
  c="${CSV_FIELDS[3]}"
  n="${CSV_FIELDS[4]}"
  r="${CSV_FIELDS[45]:--}"
  l="${CSV_FIELDS[46]:-auto}"
  count_override_provided=false

  local -a sources names conds values
  sources=("${CSV_FIELDS[5]}" "${CSV_FIELDS[9]}" "${CSV_FIELDS[13]}" "${CSV_FIELDS[17]}" "${CSV_FIELDS[21]}" "${CSV_FIELDS[25]}" "${CSV_FIELDS[29]}" "${CSV_FIELDS[33]}" "${CSV_FIELDS[37]}" "${CSV_FIELDS[41]}")
  names=("${CSV_FIELDS[6]}" "${CSV_FIELDS[10]}" "${CSV_FIELDS[14]}" "${CSV_FIELDS[18]}" "${CSV_FIELDS[22]}" "${CSV_FIELDS[26]}" "${CSV_FIELDS[30]}" "${CSV_FIELDS[34]}" "${CSV_FIELDS[38]}" "${CSV_FIELDS[42]}")
  conds=("${CSV_FIELDS[7]}" "${CSV_FIELDS[11]}" "${CSV_FIELDS[15]}" "${CSV_FIELDS[19]}" "${CSV_FIELDS[23]}" "${CSV_FIELDS[27]}" "${CSV_FIELDS[31]}" "${CSV_FIELDS[35]}" "${CSV_FIELDS[39]}" "${CSV_FIELDS[43]}")
  values=("${CSV_FIELDS[8]}" "${CSV_FIELDS[12]}" "${CSV_FIELDS[16]}" "${CSV_FIELDS[20]}" "${CSV_FIELDS[24]}" "${CSV_FIELDS[28]}" "${CSV_FIELDS[32]}" "${CSV_FIELDS[36]}" "${CSV_FIELDS[40]}" "${CSV_FIELDS[44]}")
  local i
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --domain)
      require_option_value "$@" || exit 1
      d="$2"
      _sr_assert_domain_exists "$d"
      shift 2
      ;;
    --mode)
      require_option_value "$@" || exit 1
      m="$2"
      shift 2
      ;;
    --code)
      require_option_value "$@" || exit 1
      c="$2"
      shift 2
      ;;
    --reason)
      require_option_value "$@" || exit 1
      r="${2:--}"
      shift 2
      ;;
    --loc)
      require_option_value "$@" || exit 1
      l="${2:-auto}"
      shift 2
      ;;
    --count)
      require_option_value "$@" || exit 1
      count_override_provided=true
      n="$2"
      shift 2
      [[ "$n" =~ ^(10|[1-9])$ ]] || {
        echo "[Error] count 1..10" >&2
        exit 1
      }
      local needed=$((n * 4))
      (($# >= needed)) || {
        echo "[Error] expected $needed condition args after --count" >&2
        exit 1
      }
      sources=()
      names=()
      conds=()
      values=()
      local idx=0
      while ((idx < n)); do
        sources[idx]="$1"
        names[idx]="$2"
        conds[idx]="$3"
        values[idx]="$4"
        shift 4
        idx=$((idx + 1))
      done
      ;;
    *)
      echo "[Usage] update-security-rule <id> [--domain d] [--mode and|or] [--code status] [--reason text] [--loc text] [--count n (<src> <name|-> <cond> <value|->)x n]"
      exit 1
      ;;
    esac
  done
  if [ "$count_override_provided" = true ] || [[ -n "${sources[0]-}" ]]; then
    local selector curS curN curC curV
    for ((i = 0; i < n; i++)); do
      curS="${sources[i]-}"
      curN="${names[i]-}"
      curC="${conds[i]-}"
      curV="${values[i]-}"
      _sr_validate_condition_parts "$((i + 1))" "$curS" "$curN" "$curC" "$curV" || exit 1
      if [[ -z "$curN" || "$curN" == "-" ]]; then selector="$(_sr_source_to_selector "$curS")"; else selector="$(_sr_source_to_selector "$curS" "$curN")"; fi
      _sr_validate_rule_triplet "$selector" "$curC" "$curV" "Invalid security rule update for domain '$d'" || exit 1
    done
  fi
  if [[ -n "$c" && "$c" != "-" ]]; then
    if ! is_status_code "$c"; then
      echo "[Error] Invalid status code: $c" >&2
      exit 1
    fi
  fi
  if ! is_valid_reason_value "$r"; then
    echo "[Error] Invalid reason value." >&2
    exit 1
  fi
  if ! is_valid_loc_value "$l"; then
    echo "[Error] Invalid loc value." >&2
    exit 1
  fi
  if ((n > 1)) && [[ "$m" != "and" && "$m" != "or" ]]; then
    echo "[Error] --mode required when count>1" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "update_security_rule_${id}"; then
    exit 1
  fi
  local mode_field
  if ((n == 1)); then mode_field="single"; else mode_field="$m"; fi
  d="$(normalize_domain "$d")"
  local line_values=() line
  for ((i = 0; i < 10; i++)); do
    line_values+=("${sources[i]-}" "${names[i]-}" "${conds[i]-}" "${values[i]-}")
  done
  line=$(_sr_write_db_line "$e" "$d" "$mode_field" "$c" "$n" "$r" "$l" "${line_values[@]}")
  _sr_replace_line "$id" "$line"
  echo "[Info] Updated rule $id"
  create_backup "" "UpdateSecRule_${id}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}

# Quick operator change for multi-condition rules
