# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function add_security_ip() {
  local domain="${1:-}" scope="${2:-}" action="${3:-}"
  shift 3 || true
  scope="$(printf '%s' "$scope" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$domain" ] || [[ "$scope" != "l7" && "$scope" != "l3" && "$scope" != "both" ]] || [[ "$action" != "allow" && "$action" != "deny" ]] || [ $# -lt 1 ]; then
    echo "[Usage] add-security-ip <domain> <l7|l3|both> <allow|deny> <ip...> [status_code]"
    exit 1
  fi
  domain="$(normalize_domain "$domain")"
  if ! domain_exists "$domain"; then
    echo "[Error] Unknown domain '$domain'" >&2
    exit 1
  fi
  local code=""
  if [[ "${!#}" =~ ^[0-9]{3}$ ]]; then
    code="${!#}"
    set -- "${@:1:$(($# - 1))}"
  fi
  if [ -n "$code" ] && ! is_status_code "$code"; then
    echo "[Error] Invalid status code: $code" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "add_security_ip_${domain}_${scope}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$SECURITY_IP_RULES_DB")"
  _sr_ensure_ip_db || exit 1
  # Allow a single space-separated list when coming from interactive picker
  if [ $# -eq 1 ]; then
    case "$1" in
    *" "*)
      local _arr=()
      read -r -a _arr <<<"$1"
      set -- "${_arr[@]}"
      ;;
    esac
  fi
  local ip
  for ip in "$@"; do
    if ! is_valid_ip_or_cidr "$ip"; then
      echo "[Error] Invalid IP/CIDR '$ip'" >&2
      exit 1
    fi
    if [ "$scope" = "l3" ] && _sr_is_cidr_token "$ip"; then
      echo "[Error] CIDR values are not supported for ACL scope 'l3': $ip" >&2
      exit 1
    fi
    if [ "$scope" = "both" ] && _sr_is_cidr_token "$ip"; then
      echo "[Error] CIDR values are not supported for ACL scope 'both': $ip" >&2
      exit 1
    fi
    _sr_validate_acl_cidr_deny_status "$scope" "$action" "$ip" "$code" || exit 1
    _sr_require_unique_acl_rule "$domain" "$scope" "$action" "$ip" "$code" || exit 1
  done

  for ip in "$@"; do
    csv_append_row "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER" "1" "$domain" "$scope" "$action" "$ip" "$code"
    echo "[Info] Added security IP ${scope} ${action} ${ip} for ${domain}"
  done
  create_backup "" "AddSecIP_${domain}_${scope}"
  update_nginx_config_for_security_change || { transaction_return_failure; exit 1; }
  _config_end_transaction_if_started "$started_txn"
}
