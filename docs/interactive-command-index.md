# Interactive command index

Find a command by its exact name. Each link opens its canonical procedure or
related-action table. For screenshots and task-based navigation, start at the
[documentation index](README.md).

## Basic Ops

- [`start-nginx`](guides/backends-and-ports.md#cmd-start-nginx)
- [`stop-nginx`](guides/backends-and-ports.md#cmd-stop-nginx)
- [`remove-nginx`](guides/backends-and-ports.md#cmd-remove-nginx)
- [`update-nginx-config`](guides/backends-and-ports.md#cmd-update-nginx-config)
- [`status`](guides/diagnostics-capture.md#cmd-status)
- [`status-all`](guides/diagnostics-capture.md#cmd-status-all)
- [`fix-default-config`](guides/backups-restore-cleanup.md#cmd-fix-default-config)
- [`fix-permissions`](guides/backups-restore-cleanup.md#cmd-fix-permissions)

## Backends

- [`list-backends`](guides/backends-and-ports.md#cmd-list-backends)
- [`add-backend`](guides/backends-and-ports.md#cmd-add-backend)
- [`remove-backend`](guides/backends-and-ports.md#cmd-remove-backend)
- [`start-backend`](guides/backends-and-ports.md#cmd-start-backend)
- [`stop-backend`](guides/backends-and-ports.md#cmd-stop-backend)
- [`restart-backend`](guides/backends-and-ports.md#cmd-restart-backend)
- [`update-backend`](guides/backends-and-ports.md#cmd-update-backend)
- [`replace-backend-network`](guides/backends-and-ports.md#cmd-replace-backend-network)

## Hosts & Aliases

- [`add-host-alias`](guides/hosts-and-aliases.md#cmd-add-host-alias)
- [`remove-host-alias`](guides/hosts-and-aliases.md#cmd-remove-host-alias)
- [`list-host-aliases`](guides/hosts-and-aliases.md#cmd-list-host-aliases)
- [`add-dedicated-host`](guides/hosts-and-aliases.md#cmd-add-dedicated-host)
- [`remove-dedicated-host`](guides/hosts-and-aliases.md#cmd-remove-dedicated-host)
- [`list-dedicated-hosts`](guides/hosts-and-aliases.md#cmd-list-dedicated-hosts)
- [`set-dedicated-host-inherit`](guides/hosts-and-aliases.md#cmd-set-dedicated-host-inherit)
- [`show-dedicated-host-inherit`](guides/hosts-and-aliases.md#cmd-show-dedicated-host-inherit)

## Domain Configuration

- [`init-domain-config`](guides/domain-configuration.md#cmd-init-domain-config)
- [`validate-domain-config`](guides/domain-configuration.md#cmd-validate-domain-config)
- [`apply-domain-config`](guides/domain-configuration.md#cmd-apply-domain-config)
- [`migrate-state`](guides/domain-configuration.md#cmd-migrate-state)

## Routing & Ports

- [`add-port`](guides/backends-and-ports.md#cmd-add-port)
- [`remove-port`](guides/backends-and-ports.md#cmd-remove-port)
- [`update-port`](guides/backends-and-ports.md#cmd-update-port)
- [`enable-ws`](guides/backends-and-ports.md#cmd-enable-ws)
- [`disable-ws`](guides/backends-and-ports.md#cmd-disable-ws)
- [`set-port-redirect`](guides/backends-and-ports.md#cmd-set-port-redirect)
- [`remove-port-redirect`](guides/backends-and-ports.md#cmd-remove-port-redirect)
- [`list-port-mappings`](guides/backends-and-ports.md#cmd-list-port-mappings)

## Advanced Path Routing

- [`add-path-option`](guides/path-routing.md#cmd-add-path-option)
- [`update-path-option`](guides/path-routing.md#cmd-update-path-option)
- [`remove-path-option`](guides/path-routing.md#cmd-remove-path-option)
- [`remove-all-path-options`](guides/path-routing.md#cmd-remove-all-path-options)
- [`list-path-options`](guides/path-routing.md#cmd-list-path-options)

## Port TLS & HTTP/3

- [`set-port-http3`](guides/tls-certificates-http3.md#cmd-set-port-http3)
- [`list-port-http3`](guides/tls-certificates-http3.md#cmd-list-port-http3)
- [`set-port-tls-protocols`](guides/tls-certificates-http3.md#cmd-set-port-tls-protocols)
- [`remove-port-tls-protocols`](guides/tls-certificates-http3.md#cmd-remove-port-tls-protocols)
- [`set-port-tls-ciphers`](guides/tls-certificates-http3.md#cmd-set-port-tls-ciphers)
- [`remove-port-tls-ciphers`](guides/tls-certificates-http3.md#cmd-remove-port-tls-ciphers)

## Bulk Backend Operations

- [`start-all-backends`](guides/backends-and-ports.md#cmd-start-all-backends)
- [`stop-all-backends`](guides/backends-and-ports.md#cmd-stop-all-backends)
- [`restart-all-backends`](guides/backends-and-ports.md#cmd-restart-all-backends)
- [`remove-all-backends`](guides/backends-and-ports.md#cmd-remove-all-backends)

## Certificates

- [`add-cert`](guides/tls-certificates-http3.md#cmd-add-cert)
- [`replace-cert`](guides/tls-certificates-http3.md#cmd-replace-cert)
- [`list-certs`](guides/tls-certificates-http3.md#cmd-list-certs)
- [`renew-certs`](guides/tls-certificates-http3.md#cmd-renew-certs)
- [`remove-cert`](guides/tls-certificates-http3.md#cmd-remove-cert)

## Clean & Uninstall

- [`clean-all`](guides/backups-restore-cleanup.md#cmd-clean-all)
- [`uninstall-all`](guides/backups-restore-cleanup.md#cmd-uninstall-all)

## Backend Headers

- [`add-backend-header`](guides/headers-real-ip-hsts-csp.md#cmd-add-backend-header)
- [`update-backend-header`](guides/headers-real-ip-hsts-csp.md#cmd-update-backend-header)
- [`remove-backend-header`](guides/headers-real-ip-hsts-csp.md#cmd-remove-backend-header)
- [`remove-all-backend-headers`](guides/headers-real-ip-hsts-csp.md#cmd-remove-all-backend-headers)
- [`list-backend-headers`](guides/headers-real-ip-hsts-csp.md#cmd-list-backend-headers)
- [`remove-all-headers`](guides/headers-real-ip-hsts-csp.md#cmd-remove-all-headers)
- [`set-backend-hsts`](guides/headers-real-ip-hsts-csp.md#cmd-set-backend-hsts)
- [`set-backend-csp`](guides/headers-real-ip-hsts-csp.md#cmd-set-backend-csp)

## Logging

- [`list-log-fields`](guides/diagnostics-capture.md#cmd-list-log-fields)
- [`add-log-field`](guides/diagnostics-capture.md#cmd-add-log-field)
- [`remove-log-field`](guides/diagnostics-capture.md#cmd-remove-log-field)
- [`update-log-field`](guides/diagnostics-capture.md#cmd-update-log-field)
- [`move-log-field`](guides/diagnostics-capture.md#cmd-move-log-field)

## Backend Protocol & IP Overrides

- [`set-backend-http-version`](guides/advanced-nginx-docker-options.md#cmd-set-backend-http-version)
- [`remove-backend-http-version`](guides/advanced-nginx-docker-options.md#cmd-remove-backend-http-version)
- [`set-backend-client-ip-header`](guides/headers-real-ip-hsts-csp.md#cmd-set-backend-client-ip-header)
- [`remove-backend-client-ip-header`](guides/headers-real-ip-hsts-csp.md#cmd-remove-backend-client-ip-header)
- [`set-backend-proxy-ip-header`](guides/headers-real-ip-hsts-csp.md#cmd-set-backend-proxy-ip-header)
- [`remove-backend-proxy-ip-header`](guides/headers-real-ip-hsts-csp.md#cmd-remove-backend-proxy-ip-header)

## Backend mTLS & Client Certs

- [`enable-backend-mtls`](guides/mutual-tls.md#cmd-enable-backend-mtls)
- [`disable-backend-mtls`](guides/mutual-tls.md#cmd-disable-backend-mtls)
- [`add-backend-client-cert`](guides/mutual-tls.md#cmd-add-backend-client-cert)
- [`revoke-backend-client-cert`](guides/mutual-tls.md#cmd-revoke-backend-client-cert)
- [`remove-backend-client-cert`](guides/mutual-tls.md#cmd-remove-backend-client-cert)
- [`list-backend-client-certs`](guides/mutual-tls.md#cmd-list-backend-client-certs)
- [`replace-backend-client-cert`](guides/mutual-tls.md#cmd-replace-backend-client-cert)
- [`export-backend-client-p12`](guides/mutual-tls.md#cmd-export-backend-client-p12)
- [`list-backend-cas`](guides/mutual-tls.md#cmd-list-backend-cas)
- [`replace-backend-ca`](guides/mutual-tls.md#cmd-replace-backend-ca)
- [`remove-backend-ca`](guides/mutual-tls.md#cmd-remove-backend-ca)

## Backend Access Overrides

- [`set-backend-acl-policy`](guides/access-control-security-rules.md#cmd-set-backend-acl-policy)
- [`remove-backend-acl-policy`](guides/access-control-security-rules.md#cmd-remove-backend-acl-policy)
- [`set-backend-acl-status`](guides/access-control-security-rules.md#cmd-set-backend-acl-status)
- [`remove-backend-acl-status`](guides/access-control-security-rules.md#cmd-remove-backend-acl-status)
- [`set-backend-security-rule-status`](guides/access-control-security-rules.md#cmd-set-backend-security-rule-status)
- [`remove-backend-security-rule-status`](guides/access-control-security-rules.md#cmd-remove-backend-security-rule-status)

## Access Control & Rules

- [`add-acl`](guides/access-control-security-rules.md#cmd-add-acl)
- [`remove-acl`](guides/access-control-security-rules.md#cmd-remove-acl)
- [`disable-acl`](guides/access-control-security-rules.md#cmd-disable-acl)
- [`enable-acl`](guides/access-control-security-rules.md#cmd-enable-acl)
- [`disable-all-acl`](guides/access-control-security-rules.md#cmd-disable-all-acl)
- [`enable-all-acl`](guides/access-control-security-rules.md#cmd-enable-all-acl)
- [`remove-all-acl`](guides/access-control-security-rules.md#cmd-remove-all-acl)
- [`update-acl`](guides/access-control-security-rules.md#cmd-update-acl)
- [`move-acl-rule`](guides/access-control-security-rules.md#cmd-move-acl-rule)
- [`list-acl`](guides/access-control-security-rules.md#cmd-list-acl)
- [`add-security-rule`](guides/access-control-security-rules.md#cmd-add-security-rule)
- [`update-security-rule`](guides/access-control-security-rules.md#cmd-update-security-rule)
- [`remove-security-rule`](guides/access-control-security-rules.md#cmd-remove-security-rule)
- [`remove-all-security-rules`](guides/access-control-security-rules.md#cmd-remove-all-security-rules)
- [`disable-security-rule`](guides/access-control-security-rules.md#cmd-disable-security-rule)
- [`enable-security-rule`](guides/access-control-security-rules.md#cmd-enable-security-rule)
- [`disable-all-security-rules`](guides/access-control-security-rules.md#cmd-disable-all-security-rules)
- [`enable-all-security-rules`](guides/access-control-security-rules.md#cmd-enable-all-security-rules)
- [`move-security-rule`](guides/access-control-security-rules.md#cmd-move-security-rule)
- [`set-security-rule-mode`](guides/access-control-security-rules.md#cmd-set-security-rule-mode)
- [`duplicate-security-rule`](guides/access-control-security-rules.md#cmd-duplicate-security-rule)
- [`list-security-rules`](guides/access-control-security-rules.md#cmd-list-security-rules)

## Diagnostics

- [`check-config`](guides/diagnostics-capture.md#cmd-check-config)
- [`tail-proxy-logs`](guides/diagnostics-capture.md#cmd-tail-proxy-logs)

## Updates

- [`help-update`](guides/updates.md#cmd-help-update)
- [`upgrade-preflight`](guides/updates.md#cmd-upgrade-preflight)

## Backups & Restore

- [`create-backup`](guides/backups-restore-cleanup.md#cmd-create-backup)
- [`list-backups`](guides/backups-restore-cleanup.md#cmd-list-backups)
- [`restore-backup`](guides/backups-restore-cleanup.md#cmd-restore-backup)
- [`set-auto-backups`](guides/backups-restore-cleanup.md#cmd-set-auto-backups)
- [`set-backup-retention`](guides/backups-restore-cleanup.md#cmd-set-backup-retention)
- [`set-backup-compression`](guides/backups-restore-cleanup.md#cmd-set-backup-compression)

## Global Nginx Directives

- [`set-nginx-directive`](guides/advanced-nginx-docker-options.md#cmd-set-nginx-directive)
- [`set-nginx-directive-raw`](guides/advanced-nginx-docker-options.md#cmd-set-nginx-directive-raw)
- [`remove-nginx-directive`](guides/advanced-nginx-docker-options.md#cmd-remove-nginx-directive)
- [`remove-all-nginx-directives`](guides/advanced-nginx-docker-options.md#cmd-remove-all-nginx-directives)
- [`list-nginx-directives`](guides/advanced-nginx-docker-options.md#cmd-list-nginx-directives)
- [`list-nginx-directive-catalog`](guides/advanced-nginx-docker-options.md#cmd-list-nginx-directive-catalog)
- [`set-nginx-directive-strict`](guides/advanced-nginx-docker-options.md#cmd-set-nginx-directive-strict)
- [`show-nginx-directive-strict`](guides/advanced-nginx-docker-options.md#cmd-show-nginx-directive-strict)

## Global Headers & IP

- [`control-server-tokens`](guides/headers-real-ip-hsts-csp.md#cmd-control-server-tokens)
- [`show-server-tokens`](guides/headers-real-ip-hsts-csp.md#cmd-show-server-tokens)
- [`set-client-ip-header`](guides/headers-real-ip-hsts-csp.md#cmd-set-client-ip-header)
- [`set-proxy-ip-header`](guides/headers-real-ip-hsts-csp.md#cmd-set-proxy-ip-header)
- [`add-header`](guides/headers-real-ip-hsts-csp.md#cmd-add-header)
- [`update-header`](guides/headers-real-ip-hsts-csp.md#cmd-update-header)
- [`remove-header`](guides/headers-real-ip-hsts-csp.md#cmd-remove-header)
- [`list-headers`](guides/headers-real-ip-hsts-csp.md#cmd-list-headers)
- [`set-hsts`](guides/headers-real-ip-hsts-csp.md#cmd-set-hsts)
- [`set-csp`](guides/headers-real-ip-hsts-csp.md#cmd-set-csp)
- [`set-trusted-proxies`](guides/headers-real-ip-hsts-csp.md#cmd-set-trusted-proxies)
- [`set-real-ip-recursive`](guides/headers-real-ip-hsts-csp.md#cmd-set-real-ip-recursive)

## Global Access Defaults

- [`set-security-rule-status`](guides/access-control-security-rules.md#cmd-set-security-rule-status)
- [`set-acl-status`](guides/access-control-security-rules.md#cmd-set-acl-status)
- [`set-acl-policy`](guides/access-control-security-rules.md#cmd-set-acl-policy)

## Global TLS & Runtime

- [`set-http-version`](guides/advanced-nginx-docker-options.md#cmd-set-http-version)
- [`set-tls-protocols`](guides/tls-certificates-http3.md#cmd-set-tls-protocols)
- [`set-tls-ciphers`](guides/tls-certificates-http3.md#cmd-set-tls-ciphers)
- [`set-nginx-docker-opts`](guides/advanced-nginx-docker-options.md#cmd-set-nginx-docker-opts)
- [`show-nginx-docker-opts`](guides/advanced-nginx-docker-options.md#cmd-show-nginx-docker-opts)
- [`set-visibility-policy`](guides/advanced-nginx-docker-options.md#cmd-set-visibility-policy)
- [`show-visibility-policy`](guides/advanced-nginx-docker-options.md#cmd-show-visibility-policy)
- [`set-nginx-image`](guides/advanced-nginx-docker-options.md#cmd-set-nginx-image)
- [`set-certbot-image`](guides/advanced-nginx-docker-options.md#cmd-set-certbot-image)

## Traffic Capture

- [`start-capture`](guides/diagnostics-capture.md#cmd-start-capture)
- [`stop-capture`](guides/diagnostics-capture.md#cmd-stop-capture)
