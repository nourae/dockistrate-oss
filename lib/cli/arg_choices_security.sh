# shellcheck shell=bash

function __arg_choices_mode() {
  local cmd="${1:-}"
  case "$cmd" in
  fix-permissions)
    echo "__DEFAULT__|Normalize repository permissions"
    echo "--certbot-darwin-user|Prepare Darwin Certbot mounts for sudo user mapping"
    ;;
  *)
    echo -e "and\nor"
    ;;
  esac
}

function __arg_choices_allow_or_deny() {
  local cmd="$1"
  local current=""
  case "$cmd" in
  set-backend-acl-policy)
    if [ -n "${CURRENT_ARGS[0]:-}" ]; then
      current="$(get_backend_acl_policy "${CURRENT_ARGS[0]}")"
    fi
    ;;
  set-acl-policy)
    current="$ACL_POLICY"
    ;;
  esac
  local opt
  for opt in allow deny; do
    local lbl="$opt"
    if [ -n "$current" ]; then
      local norm_cur norm_opt
      norm_cur="$(printf '%s' "$current" | tr '[:upper:]' '[:lower:]')"
      norm_opt="$(printf '%s' "$opt" | tr '[:upper:]' '[:lower:]')"
      if [ "$norm_cur" = "$norm_opt" ]; then
        lbl+=" (current)"
      fi
    fi
    csv_join_row "$opt" "$lbl"
  done
}

function __arg_choices_policy() {
  __arg_choices_allow_or_deny "$1"
}

function __arg_choices_code() {
  local cmd="$1"
  case "$cmd" in
  set-port-redirect)
    csv_join_row "301" "Moved Permanently"
    csv_join_row "302" "Found"
    csv_join_row "308" "Permanent Redirect"
    csv_join_row "__MANUAL__" "Custom (e.g., 301:443)"
    ;;
  set-backend-acl-status | set-acl-status | set-backend-security-rule-status | set-security-rule-status)
    # No fixed menu; fall back to manual entry with current default shown
    ;;
  *)
    csv_join_row "301" "Moved Permanently"
    csv_join_row "302" "Found"
    csv_join_row "308" "Permanent Redirect"
    ;;
  esac
}

function __arg_choices_source() {
  csv_join_row "header" "Header — request header (name required)"
  csv_join_row "cookie" "Cookie — request cookie (name required)"
  csv_join_row "arg" "Argument — query parameter (name required)"
  csv_join_row "method" "Method — HTTP method (GET/POST/...)"
  csv_join_row "path" "Path — normalized path"
  csv_join_row "uri" "URI — full request URI (path + args)"
  csv_join_row "host" "Host — request hostname"
  csv_join_row "scheme" "Scheme — request scheme (http/https)"
  csv_join_row "ip" "IP — client IP address"
  csv_join_row "tls_sni" "TLS SNI — server name from TLS handshake"
  csv_join_row "tls_protocol" "TLS Protocol — negotiated TLS version"
  csv_join_row "var" "Variable — Nginx variable (name required)"
}

function __arg_choices_condition() {
  local _c alias desc ex
  for _c in "${SECURITY_RULE_CONDITIONS[@]}"; do
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
    csv_join_row "$_c" "$alias — $desc. Example: $ex"
  done
}
