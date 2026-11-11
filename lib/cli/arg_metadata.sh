# shellcheck shell=bash

function arg_label() {
  case "${1:-}" in
  domain) echo "Domain" ;;
  security_rule_domain) echo "Security rule domain" ;;
  domain_config_target) echo "Domain configuration" ;;
  domain_config_kind) echo "Domain kind" ;;
  domain_config_action) echo "Review or apply" ;;
  backend_details) echo "Backend details CSV path (optional)" ;;
  image) echo "Container image" ;;
  replace_unmanaged_container) echo "Unmanaged container ID to replace" ;;
  container_port) echo "Backend container port" ;;
  nginx_port | listen | port) echo "Listen port" ;;
  protocol) echo "Protocol" ;;
  cert_path) echo "Certificate" ;;
  ws) echo "WebSocket" ;;
  docker_opts) echo "Extra Docker run options" ;;
  network) echo "Docker network" ;;
  expose) echo "Expose backend" ;;
  redirect_pref) echo "HTTP redirect" ;;
  redirect_target) echo "Redirect target port" ;;
  req_resp) echo "Header direction" ;;
  header) echo "Header name" ;;
  header_or_off) echo "Header name or off" ;;
  value) echo "Value" ;;
  on_off) echo "On or off" ;;
  directive_scope) echo "Directive scope" ;;
  directive_name) echo "Directive name" ;;
  directive_value) echo "Directive value" ;;
  path_prefix | new_path) echo "Path prefix" ;;
  target) echo "Upstream target" ;;
  rewrite) echo "Path rewrite" ;;
  alt_svc) echo "Alt-Svc" ;;
  code) echo "Status code" ;;
  policy | allow_or_deny) echo "Policy" ;;
  id) echo "ID" ;;
  hostname) echo "Hostname" ;;
  alias) echo "Alias" ;;
  port_suffix) echo "Certificate port suffix" ;;
  cert_choice) echo "Certificate type" ;;
  upload_fullchain) echo "Fullchain path" ;;
  upload_privkey) echo "Private key path" ;;
  http3) echo "HTTP/3" ;;
  redirect) echo "Redirect" ;;
  headers) echo "Header set" ;;
  match) echo "Path match type" ;;
  priority) echo "Path priority" ;;
  reason) echo "Reason" ;;
  loc) echo "Source location" ;;
  uninstall_scope) echo "Uninstall scope" ;;
  protocols) echo "TLS protocols" ;;
  ciphers) echo "TLS ciphers" ;;
  client_name) echo "Client name" ;;
  field) echo "Log field" ;;
  position) echo "Position" ;;
  from) echo "From position" ;;
  to) echo "To position" ;;
  version) echo "HTTP version" ;;
  target_tag) echo "Target tag" ;;
  require_backup) echo "Require backup" ;;
  pull_mode) echo "Image pull mode" ;;
  setting) echo "Inheritance setting" ;;
  visibility_policy) echo "Visibility policy" ;;
  inherit_mtls) echo "Inherit mTLS" ;;
  inherit_acl) echo "Inherit ACL" ;;
  inherit_security_rules) echo "Inherit security rules" ;;
  inherit_headers) echo "Inherit headers" ;;
  inherit_paths) echo "Inherit path options" ;;
  *)
    local label="${1:-}"
    label="${label//_/ }"
    echo "$label"
    ;;
  esac
}

function arg_help() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  list-security-rules:security_rule_domain)
    echo "List all rules or rules owned directly by one hostname. Global rule IDs are preserved; inherited rules are not added to a domain filter."
    return 0
    ;;
  init-domain-config:domain)
    echo "Create editable configuration templates for this domain. No container is created until you apply the completed configuration."
    return 0
    ;;
  init-domain-config:domain_config_kind)
    echo "Choose a backend container, an alias, a dedicated hostname, or certificates without a backend."
    return 0
    ;;
  validate-domain-config:domain_config_target | apply-domain-config:domain_config_target)
    echo "Select one domain or all domains. Manual edits remain pending until explicitly applied."
    return 0
    ;;
  apply-domain-config:domain_config_action)
    echo "Review validates and previews the selected configuration. Apply activates it and updates the managed services."
    return 0
    ;;
  migrate-state:domain_config_action)
    echo "Review the conversion from the legacy state layout before applying the migration."
    return 0
    ;;
  migrate-state:backend_details | restore-backup:backend_details)
    echo "Optional CSV containing backend details that cannot be recovered from existing state and managed containers."
    return 0
    ;;
  update-backend:replace_unmanaged_container)
    echo "This backend has no saved container identity. Replace its existing container with the selected image by entering its exact full 64-character ID. The old container is removed only after the replacement commits; its volumes are preserved."
    return 0
    ;;
  add-path-option:target | update-path-option:target)
    echo "Use a port, host:port, or none to keep the route on the mapped backend."
    return 0
    ;;
  add-port:alt_svc | update-port:alt_svc | set-port-http3:alt_svc)
    echo "Use auto for the default HTTP/3 advertisement, off to suppress it, or custom to type one."
    return 0
    ;;
  set-client-ip-header:header_or_off \
  | set-backend-client-ip-header:header_or_off \
  | set-proxy-ip-header:header_or_off \
  | set-backend-proxy-ip-header:header_or_off)
    echo "Use an HTTP header name, or off to disable this forwarded-header setting."
    return 0
    ;;
  set-dedicated-host-inherit:value)
    echo "Use yes to inherit the selected setting from the target backend, or no to manage it independently."
    return 0
    ;;
  add-backend:cert_path)
    echo "Certificate source for HTTPS listeners. Use selfsigned or letsencrypt to generate one, none for the default self-signed behavior, or an existing cert path."
    return 0
    ;;
  add-cert:cert_choice | replace-cert:cert_choice)
    echo "Choose how to create the certificate material."
    return 0
    ;;
  add-cert:upload_fullchain | replace-cert:upload_fullchain)
    echo "Path to an existing fullchain.pem file when uploading a custom certificate."
    return 0
    ;;
  add-cert:upload_privkey | replace-cert:upload_privkey)
    echo "Path to an existing privkey.pem file when uploading a custom certificate."
    return 0
    ;;
  restore-backup:backup)
    echo "Choose a backup name or enter a directory/.tar.gz path. Interactive confirmation comes before copying or expansion. Set RESTORE_MAX_ARCHIVE_BYTES, RESTORE_MAX_EXPANDED_BYTES, and RESTORE_MAX_ENTRIES before starting this session for larger backups."
    return 0
    ;;
  upgrade-preflight:target_tag)
    echo "Optional local release tag to compare against. Leave blank to check the current on-disk state only."
    return 0
    ;;
  upgrade-preflight:require_backup)
    echo "Use yes to fail when no local backup is present, or no to warn only."
    return 0
    ;;
  set-visibility-policy:visibility_policy)
    echo "Use full to show operator-entered Docker options, header values, and generic Nginx directive values, or redacted to hide them in display, audit, and saved interactive history."
    return 0
    ;;
  set-nginx-image:pull_mode | set-certbot-image:pull_mode)
    echo "For :latest, always and if-missing refresh on use; never skips explicit pulls. Other tags and digests skip explicit pulls in every mode. Docker may fetch a missing reference when starting a container."
    return 0
    ;;
  esac

  case "$arg_name" in
  domain)
    echo "Backend domain or host name to configure."
    ;;
  image)
    echo "Container image used when Dockistrate starts the backend."
    ;;
  container_port)
    echo "Port the backend service listens on inside its container."
    ;;
  nginx_port | listen | port)
    echo "Host-facing port handled by the Nginx proxy."
    ;;
  protocol)
    echo "Use HTTP/HTTPS for reverse proxy routes, or TCP/UDP for stream mappings."
    ;;
  cert_path)
    echo "Certificate source for HTTPS listeners. Use none for the default self-signed behavior where supported, or an existing cert path."
    ;;
  ws)
    echo "Enable WebSocket proxy headers for HTTP or HTTPS routes."
    ;;
  docker_opts)
    echo "Optional Docker run flags. Use --option=value for unrecognized long options (=true or =false for booleans). Dockistrate owns the image, name, and network; proxy options also reserve mounts, ports, and entrypoint."
    ;;
  network)
    echo "Docker network used to connect the backend and proxy."
    ;;
  expose)
    echo "Whether to expose the backend through the proxy immediately."
    ;;
  req_resp)
    echo "Choose whether the header applies to upstream requests or downstream responses."
    ;;
  header)
    echo "HTTP header name."
    ;;
  header_or_off)
    echo "HTTP header name, or off to disable the setting."
    ;;
  value)
    echo "Value to store."
    ;;
  on_off)
    echo "Enable or disable the setting."
    ;;
  directive_scope)
    echo "Where the Nginx directive should be rendered."
    ;;
  directive_name)
    echo "Nginx directive name."
    ;;
  directive_value)
    echo "Value written for the selected Nginx directive."
    ;;
  path_prefix | new_path)
    echo "Absolute request path handled by a path-level route."
    ;;
  target)
    echo "Optional upstream override for this path route."
    ;;
  rewrite)
    echo "Optional rewrite behavior for this path route."
    ;;
  alt_svc)
    echo "Alt-Svc behavior advertised for HTTP/3 listeners."
    ;;
  code)
    echo "HTTP status code used for redirects or denials."
    ;;
  policy | allow_or_deny)
    echo "Default allow/deny behavior for the selected rule set."
    ;;
  id)
    echo "Numeric row ID from the corresponding list command."
    ;;
  protocols)
    echo "Space-separated TLS protocol list for this port override."
    ;;
  ciphers)
    echo "OpenSSL cipher string for this port override."
    ;;
  cert_choice)
    echo "Certificate creation mode."
    ;;
  upload_fullchain)
    echo "Existing certificate chain file."
    ;;
  upload_privkey)
    echo "Existing private key file."
    ;;
  esac
}

function arg_example() {
  local cmd="${1:-}" arg_name="${2:-}"
  if [ "$arg_name" = cert_path ] &&
    declare -F domain_config_certificate_layout >/dev/null 2>&1 &&
    domain_config_certificate_layout; then
    if [ "$cmd" = add-backend ]; then
      echo "selfsigned, letsencrypt, example.com/selfsigned-443, or none"
    else
      echo "example.com/selfsigned-443 or none"
    fi
    return 0
  fi
  case "${cmd}:${arg_name}" in
  update-backend:replace_unmanaged_container) echo "paste the full container ID you independently verified"; return 0 ;;
  set-port-redirect:on_off) echo "on"; return 0 ;;
  set-port-redirect:code) echo "308"; return 0 ;;
  add-path-option:target | update-path-option:target) echo "none"; return 0 ;;
  set-client-ip-header:header_or_off \
  | set-backend-client-ip-header:header_or_off \
  | set-proxy-ip-header:header_or_off \
  | set-backend-proxy-ip-header:header_or_off) echo "X-Forwarded-For or off"; return 0 ;;
  set-dedicated-host-inherit:value) echo "yes"; return 0 ;;
  add-header:value | update-header:value \
  | add-backend-header:value | update-backend-header:value) echo "https"; return 0 ;;
  add-backend:cert_path) echo "selfsigned, letsencrypt, selfsigned/live/example.com_443, or none"; return 0 ;;
  add-cert:cert_choice | replace-cert:cert_choice) echo "selfsigned"; return 0 ;;
  add-cert:upload_fullchain | replace-cert:upload_fullchain) echo "/path/to/fullchain.pem"; return 0 ;;
  add-cert:upload_privkey | replace-cert:upload_privkey) echo "/path/to/privkey.pem"; return 0 ;;
  upgrade-preflight:target_tag) echo "v1.0.0"; return 0 ;;
  set-visibility-policy:visibility_policy) echo "full"; return 0 ;;
  esac

  case "$arg_name" in
  domain) echo "example.com" ;;
  security_rule_domain) echo "example.com, an alias, or a dedicated hostname" ;;
  domain_config_target) echo "example.com or --all" ;;
  backend_details) echo "/path/to/backend-details.csv" ;;
  image) echo "nginx:alpine" ;;
  container_port) echo "8000" ;;
  nginx_port | listen | port) echo "443" ;;
  protocol) echo "https" ;;
  cert_path) echo "selfsigned/live/example.com_443 or none" ;;
  docker_opts) echo "--cpus 1 --memory 256m" ;;
  network) echo "dockistrate-net" ;;
  req_resp) echo "request" ;;
  header) echo "X-Forwarded-Proto" ;;
  on_off) echo "on" ;;
  pull_mode) echo "if-missing" ;;
  directive_scope) echo "backend" ;;
  directive_name) echo "proxy_read_timeout" ;;
  directive_value) echo "60s" ;;
  path_prefix | new_path) echo "/api" ;;
  target) echo "8080 or app:8080" ;;
  rewrite) echo "strip-prefix" ;;
  alt_svc) echo "h3=\":443\"; ma=86400" ;;
  code) echo "301" ;;
  policy | allow_or_deny) echo "deny" ;;
  id) echo "1" ;;
  protocols) echo "TLSv1.2 TLSv1.3" ;;
  ciphers) echo "ECDHE+AESGCM:ECDHE+CHACHA20" ;;
  cert_choice) echo "selfsigned" ;;
  upload_fullchain) echo "/path/to/fullchain.pem" ;;
  upload_privkey) echo "/path/to/privkey.pem" ;;
  esac
}

function arg_empty_behavior() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  migrate-state:backend_details | restore-backup:backend_details)
    echo "use existing state and managed container details only"
    return 0
    ;;
  update-backend:replace_unmanaged_container)
    echo "a full container ID is required; choose Back to cancel replacement"
    return 0
    ;;
  update-backend:docker_opts | start-nginx:docker_opts | set-nginx-docker-opts:docker_opts)
    echo "leave blank to keep the shown current value"
    return 0
    ;;
  set-dedicated-host-inherit:value)
    echo "leave blank for the default yes"
    return 0
    ;;
  upgrade-preflight:target_tag)
    echo "leave blank to validate the current checkout only"
    return 0
    ;;
  esac

  case "$arg_name" in
  docker_opts)
    echo "leave blank for no extra Docker run options"
    ;;
  cert_path)
    echo "leave blank to use the default certificate behavior"
    ;;
  directive_value | value)
    echo "leave blank only when an empty value is intentional"
    ;;
  esac
}

function arg_review_label() {
  arg_label "${1:-}"
}

function arg_is_sensitive() {
  local cmd="${1:-}" arg_name="${2:-}"
  local value="${3:-}" has_value=false

  [ -n "$cmd" ] || return 1
  [ -n "$arg_name" ] || return 1
  [ "$#" -ge 3 ] && has_value=true

  if declare -F operator_visibility_is_redacted >/dev/null 2>&1 &&
    operator_visibility_is_redacted; then
    if [ "$has_value" = true ]; then
      declare -F operator_arg_value_is_redactable >/dev/null 2>&1 || return 1
      operator_arg_value_is_redactable "$cmd" "$arg_name" "$value"
      return $?
    fi
    declare -F operator_arg_is_redactable >/dev/null 2>&1 || return 1
    operator_arg_is_redactable "$cmd" "$arg_name"
    return $?
  fi

  return 1
}
