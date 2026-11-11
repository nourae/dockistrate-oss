# shellcheck shell=bash
if ! declare -F _global_settings_update_nginx_config_for_security_change >/dev/null 2>&1; then
  # shellcheck source=../global_settings/common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../global_settings" && pwd)/common.sh"
fi

function set_dedicated_host_inherit() {
  local hostname="${1:-}"
  local setting="${2:-}"
  local value="${3:-}"

  if [ -z "$hostname" ] || [ -z "$setting" ] || [ -z "$value" ]; then
    echo "[Usage] set-dedicated-host-inherit <hostname> <setting> <yes|no>"
    echo "        settings: mtls, acl, security_rules, headers, paths, all"
    exit 1
  fi

  hostname="$(normalize_domain "$hostname")"

  if ! dedicated_host_exists "$hostname"; then
    echo "[Error] Dedicated host '$hostname' not found." >&2
    exit 1
  fi

  # Validate value
  case "$value" in
    yes|no) ;;
    *)
      echo "[Error] Value must be 'yes' or 'no', got: $value" >&2
      exit 1
      ;;
  esac

  # Get current settings
  local current_mtls current_acl current_security_rules current_headers current_paths
  current_mtls="$(get_dedicated_host_inheritance "$hostname" "mtls")"
  current_acl="$(get_dedicated_host_inheritance "$hostname" "acl")"
  current_security_rules="$(get_dedicated_host_inheritance "$hostname" "security_rules")"
  current_headers="$(get_dedicated_host_inheritance "$hostname" "headers")"
  current_paths="$(get_dedicated_host_inheritance "$hostname" "paths")"

  # Update the specified setting
  case "$setting" in
    mtls)
      current_mtls="$value"
      ;;
    acl)
      current_acl="$value"
      ;;
    security_rules)
      current_security_rules="$value"
      ;;
    headers)
      current_headers="$value"
      ;;
    paths)
      current_paths="$value"
      ;;
    all)
      current_mtls="$value"
      current_acl="$value"
      current_security_rules="$value"
      current_headers="$value"
      current_paths="$value"
      ;;
    *)
      echo "[Error] Unknown setting: $setting. Use: mtls, acl, security_rules, headers, paths, or all" >&2
      exit 1
      ;;
  esac

  # Save updated settings
  local started_txn=false
  if ! transaction_is_active; then
    if ! begin_transaction "set_dedicated_host_inherit_${hostname}_${setting}" "$CONFIG_DIR"; then
      return 1
    fi
    started_txn=true
  fi
  if ! set_dedicated_host_inheritance "$hostname" "$current_mtls" "$current_acl" "$current_security_rules" "$current_headers" "$current_paths"; then
    _rollback_handler
  fi

  echo "[Info] Updated inheritance for '$hostname': $setting=$value"
  echo "[Info] Current settings: mTLS=$current_mtls, ACL=$current_acl, security_rules=$current_security_rules, headers=$current_headers, paths=$current_paths"
  log_msg "Updated dedicated host inheritance: $hostname $setting=$value"
  create_backup "" "SetDedicatedHostInherit_${hostname}_${setting}" || { transaction_return_failure; return 1; }
  case "$setting" in
  acl | security_rules | headers | all)
    # Header inheritance also chooses the trusted client IP header used by ACLs.
    _global_settings_update_nginx_config_for_security_change || { transaction_return_failure; return 1; }
    ;;
  *) update_nginx_config || { transaction_return_failure; return 1; } ;;
  esac
  if [ "$started_txn" = true ]; then
    end_transaction_success || { transaction_return_failure; return 1; }
  fi
}
