#!/usr/bin/env bash

_dockistrate_complete_backend_domain_commands() {
  local command="$1"

  case "$command" in
  add-acl | add-security-rule | set-backend-acl-policy | set-backend-acl-status | set-backend-security-rule-status | \
    add-backend-header | update-backend-header | remove-all-backend-headers | set-backend-hsts | set-backend-csp)
    if [[ $cword -eq 2 ]]; then
      local acl_domains
      acl_domains="$(__dockistrate_acl_domains)"
      COMPREPLY=($(compgen -W "$acl_domains" -- "$cur"))
      return 0
    fi
    ;;
  enable-backend-mtls | disable-backend-mtls | set-backend-http-version | set-backend-client-ip-header | set-backend-proxy-ip-header | \
    add-backend-client-cert | revoke-backend-client-cert | remove-backend-client-cert | list-backend-client-certs | \
    replace-backend-client-cert | export-backend-client-p12 | replace-backend-ca | remove-backend-ca)
    if [[ $cword -eq 2 ]]; then
      local server_domains
      server_domains="$(__dockistrate_server_domains)"
      COMPREPLY=($(compgen -W "$server_domains" -- "$cur"))
      return 0
    fi
    ;;
  update-acl | update-security-rule)
    if [[ "${prev:-}" == --domain ]]; then
      local acl_domains
      acl_domains="$(__dockistrate_acl_domains)"
      COMPREPLY=($(compgen -W "$acl_domains" -- "$cur"))
      return 0
    fi
    ;;
  remove-backend)
    if [[ $cword -eq 2 ]]; then
      local domains
      domains="$(__dockistrate_backend_domains)"
      COMPREPLY=($(compgen -W "--yes $domains" -- "$cur"))
      return 0
    fi
    if [[ $cword -eq 3 && "${COMP_WORDS[2]}" == "--yes" ]]; then
      __dockistrate_complete_backend_domains
      return 0
    fi
    ;;
  add-backend | start-backend | stop-backend | restart-backend | \
    update-backend | replace-backend-network | set-backend-client-ip-header | \
    set-backend-proxy-ip-header | add-backend-header | update-backend-header | \
    set-backend-hsts | set-backend-csp | set-backend-http-version | \
    clean-all | add-backend-client-cert | revoke-backend-client-cert | remove-backend-client-cert | \
    list-backend-client-certs | replace-backend-client-cert | \
    export-backend-client-p12 | replace-backend-ca | remove-backend-ca | \
    enable-backend-mtls | disable-backend-mtls | add-path-option | \
    update-path-option | remove-path-option | remove-all-path-options | list-path-options | \
    add-port | remove-port | update-port | set-port-redirect | \
    remove-port-redirect | enable-ws | disable-ws | remove-all-backend-headers)
    if [[ $cword -eq 2 ]]; then
      __dockistrate_complete_backend_domains
      return 0
    fi
    ;;
  esac

  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_backend_domain_commands)
