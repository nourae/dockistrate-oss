# shellcheck shell=bash

function arg_label() {
  case "${1:-}" in
  domain) echo "Domain" ;;
  image) echo "Container image" ;;
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
  setting) echo "Inheritance setting" ;;
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
  upgrade-preflight:target_tag)
    echo "Optional local release tag to compare against. Leave blank to check the current on-disk state only."
    return 0
    ;;
  upgrade-preflight:require_backup)
    echo "Use yes to fail when no local backup is present, or no to warn only."
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
    echo "Optional Docker run flags. Dockistrate still owns image, name, network, mounts, and published ports."
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
  esac
}

function arg_example() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
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
  upgrade-preflight:target_tag) echo "v1.0.0"; return 0 ;;
  esac

  case "$arg_name" in
  domain) echo "example.com" ;;
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
  esac
}

function arg_empty_behavior() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
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
  case "${cmd}:${arg_name}" in
  add-header:value | update-header:value \
    | add-backend-header:value | update-backend-header:value)
    return 0
    ;;
  esac

  case "$arg_name" in
  docker_opts)
    return 0
    ;;
  esac

  return 1
}
