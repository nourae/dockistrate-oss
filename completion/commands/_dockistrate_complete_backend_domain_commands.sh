#!/usr/bin/env bash

_dockistrate_complete_backend_domain_commands() {
  local command="$1"

  case "$command" in
  add-backend | remove-backend | start-backend | stop-backend | restart-backend | \
    update-backend | replace-backend-network | set-backend-client-ip-header | \
    set-backend-proxy-ip-header | add-backend-header | update-backend-header | \
    set-backend-hsts | set-backend-csp | set-backend-http-version | \
    set-backend-acl-policy | set-backend-acl-status | \
    set-backend-security-rule-status | add-acl | add-security-rule | \
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
