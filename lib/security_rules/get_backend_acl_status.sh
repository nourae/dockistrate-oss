# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function get_backend_acl_status() {
  local domain="${1:-}"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"
  local val="$ACL_STATUS"
  _require_persisted_settings_validation || return 1
  local has_explicit_status="no"
  if [ -n "$domain" ]; then
    local custom=""
    custom="$(get_validated_backend_setting_override "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" ACL_STATUS "$domain")" || return 1
    if [ -n "$custom" ]; then
      val="$custom"
      has_explicit_status="yes"
    fi
  fi
  # Aliases inherit absent settings; dedicated hosts can disable inheritance.
  if [ "$has_explicit_status" = "no" ]; then
    local target_domain
    target_domain="$(_acl_inherited_domain "$domain")" || return 1
    if [ -n "$target_domain" ]; then
      local target_custom=""
      target_custom="$(get_validated_backend_setting_override "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" ACL_STATUS "$target_domain")" || return 1
      [ -n "$target_custom" ] && val="$target_custom"
    fi
  fi
  validate_persisted_setting ACL_STATUS "$val" || return 1
  printf '%s\n' "$val"
}
