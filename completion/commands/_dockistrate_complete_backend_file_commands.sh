#!/usr/bin/env bash

_dockistrate_complete_backend_file_commands() {
  local command="$1"

  case "$command" in
  remove-backend-client-ip-header)
    if [[ $cword -eq 2 ]] && [ -f "$BACKEND_CLIENT_IP_HEADER_FILE" ]; then
      local domains
      domains=$(awk '{print $1}' "$BACKEND_CLIENT_IP_HEADER_FILE")
      COMPREPLY=($(compgen -W "$domains" -- "$cur"))
      return 0
    fi
    ;;
  remove-backend-proxy-ip-header)
    if [[ $cword -eq 2 ]] && [ -f "$BACKEND_PROXY_IP_HEADER_FILE" ]; then
      local domains
      domains=$(awk '{print $1}' "$BACKEND_PROXY_IP_HEADER_FILE")
      COMPREPLY=($(compgen -W "$domains" -- "$cur"))
      return 0
    fi
    ;;
  remove-backend-http-version)
    if [[ $cword -eq 2 ]] && [ -f "$BACKEND_HTTP_FILE" ]; then
      local domains
      domains=$(awk '{print $1}' "$BACKEND_HTTP_FILE")
      COMPREPLY=($(compgen -W "$domains" -- "$cur"))
      return 0
    fi
    ;;
  remove-backend-acl-policy)
    if [[ $cword -eq 2 ]] && [ -f "$BACKEND_ACL_POLICY_FILE" ]; then
      local domains
      domains=$(awk '{print $1}' "$BACKEND_ACL_POLICY_FILE")
      COMPREPLY=($(compgen -W "$domains" -- "$cur"))
      return 0
    fi
    ;;
  remove-backend-acl-status)
    if [[ $cword -eq 2 ]] && [ -f "$BACKEND_ACL_STATUS_FILE" ]; then
      local domains
      domains=$(awk '{print $1}' "$BACKEND_ACL_STATUS_FILE")
      COMPREPLY=($(compgen -W "$domains" -- "$cur"))
      return 0
    fi
    ;;
  remove-backend-security-rule-status)
    if [[ $cword -eq 2 ]] && [ -f "$BACKEND_SECURITY_RULE_STATUS_FILE" ]; then
      local domains
      domains=$(awk '{print $1}' "$BACKEND_SECURITY_RULE_STATUS_FILE")
      COMPREPLY=($(compgen -W "$domains" -- "$cur"))
      return 0
    fi
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_backend_file_commands)
