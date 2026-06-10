# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function get_backend_acl_policy() {
  local domain="${1:-}"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"
  local val="$ACL_POLICY"
  local has_explicit_policy="no"
  if [ -n "$domain" ] && [ -f "$BACKEND_ACL_POLICY_FILE" ]; then
    local custom=""
    custom="$(state_csv_get_two_col_value "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" "$domain" "" 2>/dev/null || true)"
    if [ -n "$custom" ]; then
      val="$custom"
      has_explicit_policy="yes"
    fi
  fi
  # For dedicated hosts, fall back to target domain's ACL policy if:
  # 1. No explicit config exists for the dedicated host
  # 2. Inheritance is enabled for ACL
  if [ "$has_explicit_policy" = "no" ]; then
    local target_domain
    target_domain="$(backend_for_dedicated_host "$domain")"
    if [ -n "$target_domain" ]; then
      # Check if inheritance is enabled (defaults to yes if function not available)
      local should_inherit="yes"
      if command -v should_inherit_acl >/dev/null 2>&1; then
        should_inherit_acl "$domain" && should_inherit="yes" || should_inherit="no"
      fi
      if [ "$should_inherit" = "yes" ] && [ -f "$BACKEND_ACL_POLICY_FILE" ]; then
        local target_custom=""
        target_custom="$(state_csv_get_two_col_value "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" "$target_domain" "" 2>/dev/null || true)"
        [ -n "$target_custom" ] && val="$target_custom"
      fi
    fi
  fi
  echo "$val"
}
