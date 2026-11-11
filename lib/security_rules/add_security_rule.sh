# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function add_security_rule() {
  if [ $# -lt 2 ]; then
    echo "[Usage] add-security-rule <domain> <count|and|or> (<source> <name|-> <condition> <value|->)x1..10 [--action require|block|allow] [--mode and|or] [--code status] [--reason text] [--loc text]"
    exit 1
  fi
  local domain="$1"
  shift
  _sr_assert_domain_exists "$domain"
  domain="$(normalize_domain "$domain")"
  local token="$1"
  shift
  local count mode="" code="" reason="-" loc="auto" action=require
  if [[ "$token" =~ ^[0-9]+$ ]]; then count="$token"; else
    count=1
    mode="$token"
  fi

  # Options may precede, follow, or separate complete condition tuples. Values
  # inside a tuple remain literal arguments, including strings such as --action.
  if [[ $# -gt 0 ]]; then
    local _rest=()
    while [[ $# -gt 0 ]]; do
      if [ "$((${#_rest[@]} % 4))" -eq 0 ]; then
        case "$1" in
        --action)
          require_option_value "$@" || exit 1
          action="$2"
          shift 2
          continue
          ;;
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
        esac
      fi
      _rest+=("$1")
      shift
    done
    # Rebuild positional params with only condition args
    if [ "${#_rest[@]}" -gt 0 ]; then
      set -- "${_rest[@]}"
    else
      set --
    fi
  fi
  action="$(_sr_normalize_action "$action")" || exit 1
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
  (($# == need)) || {
    echo "[Error] expected exactly $need condition args, got $#" >&2
    exit 1
  }
  local parts=() i
  for ((i = 1; i <= count; i++)); do
    parts+=("$1" "$2" "$3" "$4")
    shift 4
  done
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
  local line=""
  if ! line="$(_sr_write_db_line_with_action "$action" 1 "$domain" "$mode_field" "$code" "$count" "$reason" "$loc" "${parts[@]}")"; then
    echo "[Error] Failed to build security rule state for domain '$domain'." >&2
    exit 1
  fi

  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "add_security_rule_${domain}"; then
    return 1
  fi
  if ! domain_exists "$domain"; then
    echo "[Error] Domain '$domain' was removed before the security rule could be saved." >&2
    transaction_return_failure || true
    return 1
  fi
  if ! mkdir -p "$(dirname "$SECURITY_RULES_DB")" || ! _sr_ensure_rules_db; then
    transaction_return_failure || true
    return 1
  fi
  if ! printf '%s\n' "$line" >>"$SECURITY_RULES_DB"; then
    transaction_return_failure || true
    return 1
  fi
  echo "[Info] Added $action rule for $domain ($count condition$( ((count > 1)) && echo s))"
  if ! create_backup "" "AddSecRule_${domain}" || ! update_nginx_config_for_security_change; then
    transaction_return_failure || true
    return 1
  fi
  if ! _config_end_transaction_if_started "$started_txn"; then
    transaction_return_failure || true
    return 1
  fi
}
