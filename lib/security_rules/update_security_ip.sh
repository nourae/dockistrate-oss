# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function update_security_ip() {
  local id="${1:-}"
  shift || true
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "[Usage] update-security-ip <id> [--domain d] [--scope l7|l3|both] [--action allow|deny] [--ip x.x.x.x|CIDR] [--code status]"
    exit 1
  fi
  [ -f "$SECURITY_IP_RULES_DB" ] || {
    echo "[Error] No security IP rules configured." >&2
    exit 1
  }
  local cur
  cur="$(_sr_ip_load_line "$id" || true)"
  [ -n "$cur" ] || {
    echo "[Error] Rule $id not found" >&2
    exit 1
  }
  if ! csv_parse_line "$cur" || [ "$CSV_FIELD_COUNT" -ne "$STATE_SECURITY_IP_RULES_COLS" ]; then
    echo "[Error] Rule $id is malformed" >&2
    exit 1
  fi
  local enabled d scope action ip code
  enabled="${CSV_FIELDS[0]}"
  d="${CSV_FIELDS[1]}"
  scope="${CSV_FIELDS[2]}"
  action="${CSV_FIELDS[3]}"
  ip="${CSV_FIELDS[4]}"
  code="${CSV_FIELDS[5]}"
  local nd="$d" ns="$scope" na="$action" nip="$ip" ncode="$code"
  local domain_changed=false action_changed=false ip_changed=false code_changed=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --domain)
      require_option_value "$@" || exit 1
      nd="$2"
      domain_changed=true
      shift 2
      ;;
    --scope)
      require_option_value "$@" || exit 1
      ns="$2"
      shift 2
      ;;
    --action)
      require_option_value "$@" || exit 1
      na="$2"
      action_changed=true
      shift 2
      ;;
    --ip)
      require_option_value "$@" || exit 1
      nip="$2"
      ip_changed=true
      shift 2
      ;;
    --code)
      require_option_value "$@" || exit 1
      ncode="$2"
      code_changed=true
      shift 2
      ;;
    *)
      echo "[Usage] update-security-ip <id> [--domain d] [--scope l7|l3|both] [--action allow|deny] [--ip x.x.x.x|CIDR] [--code status]"
      exit 1
      ;;
    esac
  done
  nd="$(normalize_domain "$nd")"
  ns="$(printf '%s' "$ns" | tr '[:upper:]' '[:lower:]')"
  if $domain_changed && ! domain_exists "$nd"; then
    echo "[Error] Unknown domain '$nd'" >&2
    exit 1
  fi
  if [[ "$ns" != "l7" && "$ns" != "l3" && "$ns" != "both" ]]; then
    echo "[Error] Invalid scope '$ns' (expected l7, l3, or both)" >&2
    exit 1
  fi
  if [[ "$na" != "allow" && "$na" != "deny" ]]; then
    echo "[Error] Invalid action '$na' (expected allow or deny)" >&2
    exit 1
  fi
  if [ -n "$ncode" ]; then
    if ! is_status_code "$ncode"; then
      echo "[Error] Invalid status code: $ncode" >&2
      exit 1
    fi
  elif $code_changed; then
    ncode=""
  fi
  local validate_ip=false
  if $ip_changed; then validate_ip=true; fi
  if [[ "$ns" == "l3" || "$ns" == "both" ]]; then validate_ip=true; fi
  if $validate_ip; then
    if [ -n "$nip" ] && ! is_valid_ip_or_cidr "$nip"; then
      echo "[Error] Invalid IP/CIDR '$nip'" >&2
      exit 1
    fi
    if [[ "$ns" == "l3" && -n "$nip" ]] && _sr_is_cidr_token "$nip"; then
      echo "[Error] CIDR values are not supported for ACL scope 'l3': $nip" >&2
      exit 1
    fi
    if [[ "$ns" == "both" && -n "$nip" ]] && _sr_is_cidr_token "$nip"; then
      echo "[Error] CIDR values are not supported for ACL scope 'both': $nip" >&2
      exit 1
    fi
  fi
  _sr_validate_acl_cidr_deny_status "$ns" "$na" "$nip" "$ncode" || exit 1
  _sr_require_unique_acl_rule "$nd" "$ns" "$na" "$nip" "$ncode" "$id" || exit 1
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "update_security_ip_${id}"; then
    exit 1
  fi
  _sr_ip_replace_line "$id" "$(csv_join_row "$enabled" "$nd" "$ns" "$na" "$nip" "$ncode")"
  echo "[Info] Updated security IP rule $id"
  create_backup "" "UpdateSecIP_${id}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
