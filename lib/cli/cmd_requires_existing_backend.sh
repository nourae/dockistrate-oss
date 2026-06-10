# shellcheck shell=bash

function cmd_requires_existing_backend() {
  case "$1" in
  start-backend | stop-backend | restart-backend | remove-backend | update-backend | replace-backend-network | add-host-alias | remove-host-alias | list-host-aliases | add-dedicated-host | add-port | remove-port | update-port | add-path-option | update-path-option | remove-path-option | remove-all-path-options | list-path-options | enable-ws | disable-ws | add-backend-header | update-backend-header | remove-backend-header | remove-all-backend-headers | list-backend-headers | set-backend-hsts | set-backend-csp | set-backend-http-version | remove-backend-http-version | enable-backend-mtls | disable-backend-mtls | add-backend-client-cert | remove-backend-client-cert | list-backend-client-certs | replace-backend-client-cert | export-backend-client-p12 | list-backend-cas | replace-backend-ca | remove-backend-ca | set-backend-client-ip-header | remove-backend-client-ip-header | set-backend-proxy-ip-header | remove-backend-proxy-ip-header | set-backend-acl-policy | remove-backend-acl-policy | set-backend-acl-status | remove-backend-acl-status | set-backend-security-rule-status | remove-backend-security-rule-status | add-acl | add-security-rule | update-security-rule)
    return 0
    ;;
  esac
  return 1
}
