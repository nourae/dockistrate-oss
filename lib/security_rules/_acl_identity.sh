# shellcheck shell=bash

# Ordinary aliases always inherit absent ACL settings. Dedicated hosts retain
# their explicit inheritance switch. An empty result means use global defaults.
function _acl_inherited_domain() {
  local domain="${1:-}" target="" inherit=""
  target="$(backend_for_alias "$domain")" || return 1
  if [ -z "$target" ]; then
    target="$(backend_for_dedicated_host "$domain")" || return 1
    if [ -n "$target" ]; then
      inherit="$(get_dedicated_host_inheritance "$domain" acl)" || return 1
      [ "$inherit" = yes ] || target=""
    fi
  fi
  printf '%s\n' "$target"
}

# 0: explicit ACL, 1: no explicit ACL, 2: invalid state. Keep the alias split
# decision consistent with the rows the HTTP ACL builder actually consumes.
function _alias_has_explicit_acl() {
  local domain="${1:-}" custom="" line="" line_no=0 found=false
  local scope="" action="" ip="" code=""
  custom="$(get_validated_backend_setting_override "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" ACL_POLICY "$domain")" || return 2
  [ -z "$custom" ] || found=true
  custom="$(get_validated_backend_setting_override "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" ACL_STATUS "$domain")" || return 2
  [ -z "$custom" ] || found=true
  if [ -f "$SECURITY_IP_RULES_DB" ]; then
    csv_require_header "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER" || return 2
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      csv_parse_line "$line" || return 2
      [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || return 2
      [ "${CSV_FIELDS[0]-}" = 1 ] || continue
      [ "$(normalize_domain "${CSV_FIELDS[1]-}")" = "$domain" ] || continue
      scope="${CSV_FIELDS[2]-}" action="${CSV_FIELDS[3]-}"
      ip="${CSV_FIELDS[4]-}" code="${CSV_FIELDS[5]-}"
      case "$scope" in
      l7 | L7) scope=l7 ;;
      l3 | L3) scope=l3 ;;
      both | BOTH | Both) scope=both ;;
      *) _persisted_acl_error "$line_no" "$domain" "Invalid ACL scope '${scope}'"; return 2 ;;
      esac
      case "$action" in
      allow | deny) ;;
      *) _persisted_acl_error "$line_no" "$domain" "Invalid ACL action '${action}'"; return 2 ;;
      esac
      _persisted_acl_validate_row "$line_no" "$domain" "$scope" "$action" "$ip" "$code" http || return 2
      found=true
    done <"$SECURITY_IP_RULES_DB"
  fi
  [ "$found" = true ]
}
