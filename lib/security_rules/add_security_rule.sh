# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function add_security_rule() {
  if [ $# -lt 2 ]; then
    echo "[Usage] add-security-rule <domain> <count|and|or> (<source> <name|-> <condition> <value|->)x1..10 [--mode and|or] [--code status] [--reason text] [--loc text]"
    exit 1
  fi
  local domain="$1"
  shift
  _sr_assert_domain_exists "$domain"
  domain="$(normalize_domain "$domain")"
  local token="$1"
  shift
  local count mode="" code="" reason="-" loc="auto"
  if [[ "$token" =~ ^[0-9]+$ ]]; then count="$token"; else
    count=1
    mode="$token"
  fi

  # Accept --mode/--code anywhere among the remaining args (before or after conditions)
  # Normalize by extracting them first, leaving only condition quads in positional args
  if [[ $# -gt 0 ]]; then
    local _rest=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
      --mode)
        require_option_value "$@" || exit 1
        mode="$2"
        shift 2
        continue
        ;;
      --code)
        require_option_value "$@" || exit 1
        code="$2"
        shift 2
        continue
        ;;
      --reason)
        require_option_value "$@" || exit 1
        reason="${2:--}"
        shift 2
        continue
        ;;
      --loc)
        require_option_value "$@" || exit 1
        loc="${2:-auto}"
        shift 2
        continue
        ;;
      *)
        _rest+=("$1")
        shift
        ;;
      esac
    done
    # Rebuild positional params with only condition args
    set -- "${_rest[@]}"
  fi
  if ! [[ "$count" =~ ^(10|[1-9])$ ]]; then
    echo "[Error] count must be 1..10" >&2
    exit 1
  fi
  if ((count > 1)) && [[ "${mode:-}" != "and" && "${mode:-}" != "or" ]]; then
    echo "[Error] --mode and|or required when count>1" >&2
    exit 1
  fi
  if [ -n "$code" ]; then
    if ! is_status_code "$code"; then
      echo "[Error] Invalid status code: $code" >&2
      exit 1
    fi
  fi
  if ! is_valid_reason_value "$reason"; then
    echo "[Error] Invalid reason value." >&2
    exit 1
  fi
  if ! is_valid_loc_value "$loc"; then
    echo "[Error] Invalid loc value." >&2
    exit 1
  fi
  local need=$((count * 4))
  (($# >= need)) || {
    echo "[Error] expected $need condition args" >&2
    exit 1
  }
  local parts=() i
  for ((i = 1; i <= count; i++)); do
    parts+=("$1" "$2" "$3" "$4")
    shift 4
  done
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "add_security_rule_${domain}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$SECURITY_RULES_DB")"
  _sr_ensure_rules_db || exit 1
  local mode_field
  if ((count == 1)); then mode_field="single"; else mode_field="${mode:-and}"; fi
  # Validate operators per selector prior to saving
  local idx=0 sel src name cond val
  for ((i = 1; i <= count; i++)); do
    src="${parts[$idx]}"
    name="${parts[$((idx + 1))]}"
    cond="${parts[$((idx + 2))]}"
    val="${parts[$((idx + 3))]}"
    idx=$((idx + 4))
    _sr_validate_condition_parts "$i" "$src" "$name" "$cond" "$val" || exit 1
    local selector
    if [[ -z "$name" || "$name" == "-" ]]; then
      selector="$(_sr_source_to_selector "$src")"
    else
      selector="$(_sr_source_to_selector "$src" "$name")"
    fi
    _sr_validate_rule_triplet "$selector" "$cond" "$val" "Invalid security rule for domain '$domain'" || exit 1
  done
  local line=$(_sr_write_db_line 1 "$domain" "$mode_field" "$code" "$count" "$reason" "$loc" "${parts[@]}")
  echo "$line" >>"$SECURITY_RULES_DB"
  echo "[Info] Added rule for $domain ($count condition$( ((count > 1)) && echo s))"
  create_backup "" "AddSecRule_${domain}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
