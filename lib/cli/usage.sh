# shellcheck shell=bash

#######################################
# Usage
#######################################
function usage() {
  cat <<EOF
Usage: $0 [--version] [-v|--verbose] [-i|--interactive] <command> [args]

Options:
  --version, version      Print the Dockistrate version and exit
  -v, --verbose           Print logged actions to the console
  -i, --interactive       Open interactive picker to choose a command

Basic Commands:
  start-nginx             Start or recreate the Nginx proxy container [--nginx-image image[:tag]] [--docker-opts opts]
  stop-nginx              Stop the Nginx proxy container if it is running
  remove-nginx            Remove the Nginx proxy container
  status                  Show overall status (containers, CPU/mem, etc.)
  status-all              Show the full operator status report with paths, certs, Docker opts, and diagnostics
  list-backends           Show extended info about backends
  fix-default-config      Recreate default Nginx configuration/certificates
  update-nginx-config     Regenerate applied Nginx configuration; pending domain edits stay pending
  init-domain-config <domain> [--kind backend|alias|dedicated|certificate-only]
  validate-domain-config <domain>|--all
  apply-domain-config <domain>|--all [--dry-run]
  migrate-state [--dry-run] [--backend-details <csv>]
  fix-permissions [--certbot-darwin-user|target_dir]
                          Repair selected-directory permissions, or prepare Darwin Certbot mounts

Backends:
  add-backend <domain> <image> <container_port> <http|https|tcp|udp> [--listen port] [--cert selfsigned|letsencrypt|none|path] [--ws yes|no] [--docker-opts opts] [--network net] [--no-expose|--expose yes|no]
  # To create backend without exposing a port initially: add-backend ... --no-expose
  remove-backend [--yes] <domain>
  add-host-alias <alias> <domain>
  remove-host-alias <alias>
  list-host-aliases [domain]
  add-dedicated-host <hostname> <domain> [inherit_mtls] [inherit_acl] [inherit_security_rules] [inherit_headers] [inherit_paths]
  remove-dedicated-host <hostname>
  list-dedicated-hosts [domain]
  set-dedicated-host-inherit <hostname> <mtls|acl|security_rules|headers|paths|all> <yes|no>
  show-dedicated-host-inherit <hostname>
  start-backend <domain>
  stop-backend <domain>
  restart-backend <domain>
  update-backend <domain> [--image img] [--container-port port] [--docker-opts opts] [--network net] [--replace-unmanaged-container full-id]
    Replacement requires --image and no saved backend identity; supply the exact full 64-character container ID.
  replace-backend-network <domain> <network>
  # Port Mappings (by backend domain)
  add-port <domain> <nginx_port> <container_port> <http|https|tcp|udp> <cert_path|none> [yes|no ws] [--http3 on|off] [--alt-svc auto|off|custom]
  # HTTPS with 'none' will mint a self-signed certificate automatically
  remove-port <domain> <nginx_port>
  update-port <domain> [current_port] [--nginx-port port] [--container-port port] [--protocol http|https|tcp|udp] [--cert path|none] [--ws yes|no] [--http3 on|off] [--alt-svc auto|off|custom]
  set-port-http3 <port> <on|off> [alt-svc auto|off|custom]
  list-port-http3 [port]
  set-port-redirect <domain> <port> <on|off> [301|302|308[:target_port]]
  remove-port-redirect <domain> <port>
  add-path-option <domain> <nginx_port> <path_prefix> [--ws yes|no|inherit] [--redirect inherit|off|301|302|308] [--headers name|none] [--match prefix|exact|regex] [--priority n] [--target host:port|port] [--rewrite none|strip-prefix|replace:/new] [--reason text] [--loc value]
  update-path-option <domain> <nginx_port> <path_prefix> [--new-path prefix] [--nginx-port port] [--ws yes|no|inherit] [--redirect inherit|off|301|302|308] [--headers name|none] [--match prefix|exact|regex] [--priority n] [--target host:port|port|none] [--rewrite none|strip-prefix|replace:/new] [--reason text] [--loc value]
  remove-path-option <domain> <nginx_port> <path_prefix>
  remove-all-path-options [domain]
  list-path-options [domain] [nginx_port]
  list-port-mappings
  enable-ws <domain> <port>
  disable-ws <domain> <port>
  start-all-backends
  stop-all-backends
  restart-all-backends
  remove-all-backends

Certificates:
  add-cert <domain> [port_suffix] [selfsigned|letsencrypt|upload] [fullchain] [privkey]
  replace-cert <domain> [port_suffix] [selfsigned|letsencrypt|upload] [fullchain] [privkey]
  list-certs
  renew-certs             Scan configured HTTPS certificates, renew expiring Let's Encrypt certificates, and refresh Nginx config
  remove-cert <domain> [port_suffix]

Port TLS Overrides:
  set-port-tls-protocols <port> <protocols>
  remove-port-tls-protocols <port>
  set-port-tls-ciphers <port> <cipher_string>
  remove-port-tls-ciphers <port>

Nginx Directive Overrides:
  set-nginx-directive <global|backend|port|path|stream-global|stream-backend|stream-port> [domain] [listen_port] [path_prefix] <directive> <value>
  set-nginx-directive-raw <global|backend|port|path|stream-global|stream-backend|stream-port> [domain] [listen_port] [path_prefix] <directive> <value>
  remove-nginx-directive <global|backend|port|path|stream-global|stream-backend|stream-port> [domain] [listen_port] [path_prefix] <directive>
  remove-all-nginx-directives [all|global|backend <domain>|port <domain> <listen_port>|path <domain> <listen_port> <path_prefix>|stream-global|stream-backend <domain>|stream-port <domain> <listen_port>]
  list-nginx-directives [all|global|backend <domain>|port <domain> <listen_port>|path <domain> <listen_port> <path_prefix>|stream-global|stream-backend <domain>|stream-port <domain> <listen_port>]
  list-nginx-directive-catalog
  set-nginx-directive-strict <on|off>
  show-nginx-directive-strict

Clean & Uninstall:
  clean-all <domain>
  uninstall-all [--scope backend|config|all]

Headers & Tokens:
  control-server-tokens <on|off>
  show-server-tokens
  set-client-ip-header <header|off>
  set-backend-client-ip-header <domain> <header|off>
  remove-backend-client-ip-header <domain>
  set-proxy-ip-header <header|off>
  set-backend-proxy-ip-header <domain> <header|off>
  remove-backend-proxy-ip-header <domain>
  add-header <request|response> <name> <value>
  update-header <request|response> <name> <value>
  remove-header <request|response> <name>
  list-headers
  remove-all-headers
  add-backend-header <domain> <request|response> <name> <value>
  update-backend-header <domain> <request|response> <name> <value>
  remove-backend-header <domain> <request|response> <name>
  list-backend-headers <domain>
  remove-all-backend-headers <domain>
  set-hsts <value|off>
  set-backend-hsts <domain> <value|off>
  set-csp <policy|off>
  set-backend-csp <domain> <policy|off>

Logging:
  list-log-fields
  add-log-field <field> [position]
  remove-log-field <id>
  update-log-field <id> <field>
  move-log-field <from> <to>

Backend Overrides:
  set-backend-http-version <domain> <http1.0|http1.1|http2>
  remove-backend-http-version <domain>
  # mTLS (mutual TLS) commands
  enable-backend-mtls <domain> [client_name]
  disable-backend-mtls <domain>
  add-backend-client-cert <domain> <client_name>
  remove-backend-client-cert <domain> <client_name>
  revoke-backend-client-cert <domain> <client_name>
  list-backend-client-certs <domain>
  replace-backend-client-cert <domain> <client_name>
  export-backend-client-p12 <domain> <client_name>
  list-backend-cas
  replace-backend-ca <domain>
  remove-backend-ca <domain>
  set-backend-acl-policy <domain> <allow|deny>
  remove-backend-acl-policy <domain>
  # unified ACL: no separate L3 policy commands
  set-backend-acl-status <domain> <code>
  remove-backend-acl-status <domain>
  set-backend-security-rule-status <domain> <code>
  remove-backend-security-rule-status <domain>

ACL & Security:
  # ACL domains include backends, ordinary aliases, and dedicated hosts.
  # Explicit alias ACLs apply to alias HTTP/HTTPS traffic; absent settings inherit the primary.
  add-acl <domain> <l7|l3|both> <allow|deny> <ip...> [status_code]
  # IPv4 only; CIDR accepted only for l7 scope; l3 and both require exact IPs; l7 deny CIDR only supports status 403
  remove-acl <id>
  disable-acl <id>
  enable-acl <id>
  remove-all-acl
  disable-all-acl
  enable-all-acl
  update-acl <id> [--domain d] [--scope l7|l3|both] [--action allow|deny] [--ip x.x.x.x|CIDR] [--code status]
  # IPv4 only; CIDR accepted only for l7 scope; l3 and both require exact IPs; l7 deny CIDR only supports status 403
  move-acl-rule <from> <to>
  list-acl
  # New unified IP policy management (replaces ACLs)
  # (internal) security-ip commands are now aliased to ACL commands
  # Backend rules apply to aliases and dedicated hosts with security_rules inheritance enabled.
  # Request rules and status overrides accept backend, alias, and dedicated-host domains; explicit rule --code wins.
  add-security-rule <domain> <count> (<field_type> <name|-> <condition> <value|->)x<count> [--action require|block|allow] [--mode and|or] [--code status] [--reason text] [--loc text]
  set-security-rule-mode <id> <and|or>
  duplicate-security-rule <id>
  # field_type: header|cookie|arg|method|path|uri|host|scheme|ip|tls_sni|tls_protocol|var
  # notes for 'ip': optional <name> can be 'l7' (remote_addr, default) or 'l3' (realip_remote_addr)
  # CIDR values are rejected for ip/ip:l7/ip:l3 selectors (equals/not_equals/in/not_in)
  # use '-' for <name> when not required (e.g., method) and for <value> when not required (e.g., exists)
  # when <count> > 1, --mode is required
  update-security-rule <id> [--domain domain] [--action require|block|allow] [--mode and|or] [--code status] [--reason text] [--loc text] [--count n (<field_type> <name|-> <condition> <value|->)x<n>]
  # Omitted action: add defaults to require; update preserves the saved action.
  # Require rules must all pass, then the first matching Block/Allow rule wins in global order.
  # Allow skips later Block rules; it never bypasses Require, ACLs, or mTLS.
  # legacy per-operator commands were removed in favor of unified add/update
  remove-security-rule <id>
  disable-security-rule <id>
  enable-security-rule <id>
  remove-all-security-rules
  disable-all-security-rules
  enable-all-security-rules
  move-security-rule <from> <to>
  list-security-rules [domain]
    Optional domain filters directly owned rules; displayed IDs remain global.

Diagnostics:
  check-config
  tail-proxy-logs [lines]

Updates:
  help update
  help-update
  upgrade-preflight [--require-backup] [vMAJOR.MINOR.PATCH]
  # update commands are read-only and never fetch tags, inspect remotes, or apply updates

Backups & Restores:
  create-backup [desc]
  list-backups
  restore-backup <backup_name|backup_path> [--backend-details <csv>]
  # interactive confirmation precedes copying/expansion; CLI keeps automatic approval
  # restore limits (positive decimal environment values):
  # RESTORE_MAX_ARCHIVE_BYTES=1073741824 (compressed archive bytes)
  # RESTORE_MAX_EXPANDED_BYTES=4294967296 (tar stream and regular-file payload bytes)
  # RESTORE_MAX_ENTRIES=20000 (files and directories)
  # raise these limits for larger trusted backups; internal rollback is unaffected

Dynamic Global Settings:
  set-auto-backups <true|false>
  set-backup-retention <days>
  set-backup-compression <true|false>
  set-http-version <http1.0|http1.1|http2>
  set-tls-protocols <protocols>
  set-tls-ciphers <cipher_string>
  set-security-rule-status <code>
  set-acl-status <code>
  set-acl-policy <allow|deny>
  # deny + non-403 is blocked when CIDR allow ACL rules are present
  # unified ACL: no separate L3 policy
  set-trusted-proxies <cidr_list|none>
  set-real-ip-recursive <on|off>
  set-nginx-docker-opts <opts>
  show-nginx-docker-opts
  set-visibility-policy <full|redacted>
  show-visibility-policy
  set-nginx-image <image-ref> [always|if-missing|never]
  set-certbot-image <image-ref> [always|if-missing|never]

Traffic Capture:
  start-capture [folder] [--scope all|backends|clients|clients-backends] [--backends "d1 d2"] [--clients "ip1 ip2"] [--tls-decrypt]
  # --folder <folder> is an alternative to the positional output folder.
  # Restricted scopes require valid targets; invalid or unresolved restrictions fail.
  # Use --scope all without target filters for intentional full capture.
  stop-capture
EOF
  return 1
}
