# shellcheck shell=bash

#######################################
# Interactive Picker
#######################################
function _arg_option_hint_operator_value_for_display() {
  local kind="${1:-}" value="${2:-}"
  if declare -F operator_value_for_display >/dev/null 2>&1; then
    operator_value_for_display "$kind" "$value"
  else
    printf '%s' "$value"
  fi
}

function arg_option_hint() {
  case "$1" in
  allow_or_deny | policy)
    echo "allow|deny"
    ;;
  true_or_false)
    echo "true|false"
    ;;
  on_off)
    echo "on|off"
    ;;
  expose)
    echo "yes|no"
    ;;
  require_backup)
    echo "yes|no"
    ;;
  target_tag)
    echo "vMAJOR.MINOR.PATCH"
    ;;
  uninstall_scope)
    echo "backend|config|all"
    ;;
  directive_scope)
    echo "global|backend|port|path|stream-global|stream-backend|stream-port|all"
    ;;
  version)
    echo "http1.0|http1.1|http2"
    ;;
  req_resp)
    echo "request|response"
    ;;
  condition | condition1 | condition2)
    # value|Display text with description + example
    local _c
    for _c in "${SECURITY_RULE_CONDITIONS[@]}"; do
      local alias desc ex
      alias="$(condition_alias "$_c")"
      case "$_c" in
      equals)
        desc="string equals"
        ex="header X-Env equals prod"
        ;;
      not_equals)
        desc="string not equal"
        ex="header X-Debug not_equals 1"
        ;;
      contains)
        desc="substring present (case-insensitive)"
        ex="path contains /api/"
        ;;
      not_contains)
        desc="substring not present"
        ex="host not_contains internal"
        ;;
      starts_with)
        desc="string starts with"
        ex="path starts_with /admin"
        ;;
      not_starts_with)
        desc="string does not start with"
        ex="uri not_starts_with /public"
        ;;
      ends_with)
        desc="string ends with"
        ex="uri ends_with .json"
        ;;
      not_ends_with)
        desc="string does not end with"
        ex="uri not_ends_with .php"
        ;;
      matches)
        desc="regex matches (case-insensitive)"
        ex="arg token matches ^[A-Za-z0-9]+$"
        ;;
      not_matches)
        desc="regex does not match"
        ex="header X-Agent not_matches (curl|wget)"
        ;;
      in)
        desc="value is in list (comma or pipe separated)"
        ex="method in GET,POST"
        ;;
      not_in)
        desc="value is not in list"
        ex="host not_in admin.example.com,ops.example.com"
        ;;
      gt)
        desc="numeric greater than"
        ex="var request_length gt 100000"
        ;;
      ge)
        desc="numeric greater or equal"
        ex="var status ge 400"
        ;;
      lt)
        desc="numeric less than"
        ex="var request_time lt 1"
        ;;
      le)
        desc="numeric less or equal"
        ex="var request_time le 5"
        ;;
      exists)
        desc="value present / header exists"
        ex="cookie session exists -"
        ;;
      not_exists)
        desc="value missing / header not present"
        ex="header X-Debug not_exists -"
        ;;
      *)
        desc="condition"
        ex=""
        ;;
      esac
      printf "%s|%s — %s. Example: %s\n" "$_c" "$alias" "$desc" "$ex"
    done
    ;;
  mode)
    echo "and|or"
    ;;
  source)
    # Return value|description pairs for better picker UX
    echo "header|HTTP header (name required)"
    echo "cookie|Cookie (name required)"
    echo "arg|Query arg (name required)"
    echo "method|HTTP method"
    echo "path|Request path"
    echo "uri|Request URI"
    echo "host|Host"
    echo "scheme|Scheme (http/https)"
    echo "ip|Client IP (name: l7=remote_addr, l3=realip_remote_addr)"
    echo "tls_sni|TLS SNI"
    echo "tls_protocol|TLS protocol"
    echo "var|Arbitrary Nginx var (name required)"
    ;;
  scope)
    echo "l7|Layer 7 (\$remote_addr, also used for TCP streams)"
    echo "l3|Layer 3 (\$realip_remote_addr)"
    echo "both|Apply to L7 and L3 (TCP uses client IP)"
    ;;
  action)
    echo "allow|Allow"
    echo "deny|Deny"
    ;;
  protocols)
    echo "TLSv1 TLSv1.1 TLSv1.2 TLSv1.3"
    ;;
  ciphers)
    echo "OpenSSL cipher string"
    ;;
  ranges)
    echo "CIDR ranges or 'none' to clear"
    ;;
  ip_list)
    echo "ip or cidr..."
    ;;
  redirect)
    echo "inherit|off|301|302|308"
    ;;
  http3)
    echo "on|off"
    ;;
  alt_svc)
    echo "auto|off|custom"
    ;;
  headers)
    echo "header set name or 'none'"
    ;;
  match)
    echo "prefix|exact|regex"
    ;;
  priority)
    echo "location priority (integer)"
    ;;
  target)
    echo "host:port|port|none"
    ;;
  rewrite)
    echo "none|strip-prefix|replace:/new/path"
    ;;
  reason)
    echo "rule reason string or '-'"
    ;;
  loc)
    echo "location metadata (default auto)"
    ;;
  hsts_value | backend_hsts_value)
    local cur=""
    if [[ "$1" == "hsts_value" ]]; then
      cur="$(get_global_header_value "Strict-Transport-Security")"
    else
      # backend value shown via current args if available; fall back to global
      cur="$(get_global_header_value "Strict-Transport-Security")"
    fi
    [ -n "$cur" ] && echo "Current: $(_arg_option_hint_operator_value_for_display header_value "$cur"). Off to remove; e.g., max-age=63072000; includeSubDomains; preload" || echo "Off to remove; e.g., max-age=63072000; includeSubDomains; preload"
    ;;
  csp_value | backend_csp_value)
    local cur=""
    if [[ "$1" == "csp_value" ]]; then
      cur="$(get_global_header_value "Content-Security-Policy")"
    else
      cur="$(get_global_header_value "Content-Security-Policy")"
    fi
    [ -n "$cur" ] && echo "Current: $(_arg_option_hint_operator_value_for_display header_value "$cur"). Off to remove; e.g., default-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests" || echo "Off to remove; e.g., default-src 'self'; frame-ancestors 'none'; upgrade-insecure-requests"
    ;;
  esac
}
