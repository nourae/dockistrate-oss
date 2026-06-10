# shellcheck shell=bash

# Return codes: 0 handled, 1 back/abort, 2 not handled
function prompt_args_handle_security_specials() {
  local CMD="$1" spec="${2:-}"
  case "$CMD" in
  add-acl)
    prompt_args_handle_add_acl_interactive "$CMD" "$spec"
    return $?
    ;;
  add-security-rule)
    prompt_args_handle_add_security_rule_interactive "$CMD"
    return $?
    ;;
  update-security-rule)
    prompt_args_handle_update_security_rule_interactive "$CMD"
    return $?
    ;;
  esac
  return 2
}
