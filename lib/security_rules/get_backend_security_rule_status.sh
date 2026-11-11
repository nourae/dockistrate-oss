# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function get_backend_security_rule_status() {
  local domain="${1:-}"
  local val="$SECURITY_RULE_STATUS"
  _require_persisted_settings_validation || return 1
  local has_explicit_status="no"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"
  if [ -n "$domain" ]; then
    local custom=""
    custom="$(get_validated_backend_setting_override "$BACKEND_SECURITY_RULE_STATUS_FILE" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" SECURITY_RULE_STATUS "$domain")" || return 1
    if [ -n "$custom" ]; then
      val="$custom"
      has_explicit_status="yes"
    fi
  fi
  # Ordinary aliases inherit absent status settings. Dedicated hosts do so only
  # when security-rule inheritance is enabled; explicit host settings win.
  if [ "$has_explicit_status" = "no" ]; then
    local target_domain should_inherit="yes"
    target_domain="$(backend_for_alias "$domain")" || return 1
    if [ -z "$target_domain" ]; then
      target_domain="$(backend_for_dedicated_host "$domain")" || return 1
      if [ -n "$target_domain" ]; then
        # Missing inheritance state defaults to yes; malformed state is an error.
        should_inherit="$(get_dedicated_host_inheritance "$domain" "security_rules")" || return 1
      fi
    fi
    if [ -n "$target_domain" ]; then
      if [ "$should_inherit" = "yes" ]; then
        local target_custom=""
        target_custom="$(get_validated_backend_setting_override "$BACKEND_SECURITY_RULE_STATUS_FILE" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" SECURITY_RULE_STATUS "$target_domain")" || return 1
        [ -n "$target_custom" ] && val="$target_custom"
      fi
    fi
  fi
  validate_persisted_setting SECURITY_RULE_STATUS "$val" || return 1
  printf '%s\n' "$val"
}
