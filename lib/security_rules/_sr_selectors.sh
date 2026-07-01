# shellcheck shell=bash

function _sr_allowed_ops_for_selector() {
  local sel="$1"
  case "$sel" in
  header:*) echo "equals not_equals contains not_contains starts_with not_starts_with ends_with not_ends_with matches not_matches in not_in exists not_exists" ;;
  cookie:*) echo "equals not_equals contains not_contains starts_with not_starts_with ends_with not_ends_with matches not_matches in not_in exists not_exists" ;;
  arg:*) echo "equals not_equals contains not_contains starts_with not_starts_with ends_with not_ends_with matches not_matches in not_in exists not_exists" ;;
  method) echo "equals not_equals in not_in" ;;
  scheme) echo "equals not_equals" ;;
  host) echo "equals not_equals contains not_contains starts_with not_starts_with ends_with not_ends_with matches not_matches in not_in" ;;
  path | uri) echo "equals not_equals contains not_contains starts_with not_starts_with ends_with not_ends_with matches not_matches" ;;
  ip | ip:l7 | ip:l3)
    echo "equals not_equals in not_in"
    ;;
  tls_sni) echo "equals not_equals contains not_contains starts_with not_starts_with ends_with not_ends_with matches not_matches in not_in" ;;
  tls_protocol) echo "equals in" ;;
  var:*) echo "equals not_equals contains not_contains starts_with not_starts_with ends_with not_ends_with matches not_matches in not_in gt ge lt le exists not_exists" ;;
  *) echo "equals not_equals" ;;
  esac
}

# Validate that a condition is allowed for the selector; print helpful error when invalid

function _sr_validate_selector_condition() {
  local selector="$1" cond="$2"
  local allowed ops
  allowed="$(_sr_allowed_ops_for_selector "$selector")"
  for ops in $allowed; do
    if [ "$ops" = "$cond" ]; then
      return 0
    fi
  done
  echo "[Error] Condition '$cond' is not allowed for '$selector'. Allowed: $allowed" >&2
  return 1
}

# Pretty alias for condition names

function _sr_source_to_selector() {
  local src="$1" name="${2:-}"
  case "$src" in
  header) echo "header:${name}" ;;
  cookie) echo "cookie:${name}" ;;
  arg) echo "arg:${name}" ;;
  ip)
    # Allow optional name to differentiate L7 vs L3 IP
    case "$name" in
    l3 | real | realip) echo "ip:l3" ;;
    l7 | remote | client | -) echo "ip:l7" ;;
    "" | *) echo "ip" ;;
    esac
    ;;
  method | path | uri | host | scheme | tls_sni | tls_protocol) echo "$src" ;;
  var) echo "var:${name}" ;;
  *) echo "header:${src}" ;;
  esac
}

# Generators (single and multi)

function _sr_selector_to_var() {
  local sel="$1" _var="$2" _label="$3"
  local var label
  case "$sel" in
  header:*)
    local h="${sel#header:}"
    var="$(nginx_header_var "$h")"
    label="header:${h}"
    ;;
  cookie:*)
    local c="${sel#cookie:}"
    var="\$cookie_${c//-/_}"
    label="cookie:${c}"
    ;;
  arg:*)
    local a="${sel#arg:}"
    var="\$arg_${a//-/_}"
    label="arg:${a}"
    ;;
  method)
    var="\$request_method"
    label="method"
    ;;
  path)
    var="\$uri"
    label="path"
    ;;
  uri)
    var="\$request_uri"
    label="uri"
    ;;
  host)
    var="\$host"
    label="host"
    ;;
  scheme)
    var="\$scheme"
    label="scheme"
    ;;
  ip)
    var="\$remote_addr"
    label="ip:l7"
    ;;
  ip:*)
    # ip:l7 -> $remote_addr, ip:l3|ip:real -> $realip_remote_addr
    local kind="${sel#ip:}"
    case "$kind" in
    l3 | real | realip)
      var="\$realip_remote_addr"
      label="ip:l3"
      ;;
    l7 | remote | client | -)
      var="\$remote_addr"
      label="ip:l7"
      ;;
    *)
      var="\$remote_addr"
      label="ip:${kind}"
      ;;
    esac
    ;;
  tls_sni)
    var="\$ssl_server_name"
    label="tls_sni"
    ;;
  tls_protocol)
    var="\$ssl_protocol"
    label="tls_protocol"
    ;;
  var:*)
    local v="${sel#var:}"
    [[ "$v" == \$* ]] && var="$v" || var="\$${v}"
    label="var:${v#\$}"
    ;;
  *)
    var="$(nginx_header_var "$sel")"
    label="header:${sel}"
    ;;
  esac
  printf -v "${_var}" '%s' "$var"
  printf -v "${_label}" '%s' "$label"
}

function _sr_expr_trim_list_token() {
  printf '%s' "${1:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

function _sr_exact_list_regex() {
  local raw="${1:-}" normalized="" token="" escaped="" joined="" sep=""
  local -a tokens=()

  normalized="${raw//|/,}"
  case "$normalized" in
  "" | ,* | *, | *,,*)
    return 1
    ;;
  esac
  IFS=',' read -r -a tokens <<<"$normalized"
  [ "${#tokens[@]}" -gt 0 ] || return 1

  for token in "${tokens[@]}"; do
    token="$(_sr_expr_trim_list_token "$token")"
    [ -n "$token" ] || return 1
    escaped="$(_sr_escape_regex_literal "$token")"
    joined="${joined}${sep}${escaped}"
    sep="|"
  done

  [ -n "$joined" ] || return 1
  printf '^(?:%s)$' "$joined"
}

function _sr_exprs() {
  # Return display\x1f fail_predicate\x1f pass_predicate via stdout to avoid
  # nameref/local scope issues on Bash 3.
  local cond="$1" val="$2"
  local display_value="" fail_predicate="" pass_predicate="" sep=$'\x1f'
  case "$cond" in
  secret_header | equals)
    display_value="${val}"
    fail_predicate="!= \"${val}\""
    pass_predicate="= \"${val}\""
    ;;
  not_equals)
    fail_predicate="= \"${val}\""
    pass_predicate="!= \"${val}\""
    ;;
  contains)
    local re_contains="$(_sr_escape_regex_literal "${val}")"
    display_value="${val}"
    fail_predicate="!~* \"${re_contains}\""
    pass_predicate="~* \"${re_contains}\""
    ;;
  not_contains)
    local re_not_contains="$(_sr_escape_regex_literal "${val}")"
    fail_predicate="~* \"${re_not_contains}\""
    pass_predicate="!~* \"${re_not_contains}\""
    ;;
  starts_with)
    local re_starts="$(_sr_escape_regex_literal "${val}")"
    display_value="${val}"
    fail_predicate="!~* \"^${re_starts}\""
    pass_predicate="~* \"^${re_starts}\""
    ;;
  not_starts_with)
    local re_not_starts="$(_sr_escape_regex_literal "${val}")"
    fail_predicate="~* \"^${re_not_starts}\""
    pass_predicate="!~* \"^${re_not_starts}\""
    ;;
  ends_with)
    local re_ends="$(_sr_escape_regex_literal "${val}")"
    display_value="${val}"
    fail_predicate="!~* \"${re_ends}$\""
    pass_predicate="~* \"${re_ends}$\""
    ;;
  not_ends_with)
    local re_not_ends="$(_sr_escape_regex_literal "${val}")"
    fail_predicate="~* \"${re_not_ends}$\""
    pass_predicate="!~* \"${re_not_ends}$\""
    ;;
  matches)
    display_value="${val}"
    fail_predicate="!~* \"(${val})\""
    pass_predicate="~* \"(${val})\""
    ;;
  not_matches)
    fail_predicate="~* \"(${val})\""
    pass_predicate="!~* \"(${val})\""
    ;;
  in)
    local re_in
    re_in="$(_sr_exact_list_regex "$val")" || return 1
    display_value="${val}"
    fail_predicate="!~* \"${re_in}\""
    pass_predicate="~* \"${re_in}\""
    ;;
  not_in)
    local re_not_in
    re_not_in="$(_sr_exact_list_regex "$val")" || return 1
    display_value="${val}"
    fail_predicate="~* \"${re_not_in}\""
    pass_predicate="!~* \"${re_not_in}\""
    ;;
  gt)
    _sr_is_unsigned_int "$val" || return 1
    local regex_gt="$(_sr_numeric_regex_ge "$(_sr_numeric_inc "$val")")"
    display_value="0"
    fail_predicate="!~* \"^${regex_gt}$\""
    pass_predicate="~* \"^${regex_gt}$\""
    ;;
  ge)
    _sr_is_unsigned_int "$val" || return 1
    local regex_ge="$(_sr_numeric_regex_ge "$val")"
    display_value="0"
    fail_predicate="!~* \"^${regex_ge}$\""
    pass_predicate="~* \"^${regex_ge}$\""
    ;;
  lt)
    _sr_is_unsigned_int "$val" || return 1
    local regex_lt="$(_sr_numeric_regex_lt "$val")"
    display_value="0"
    fail_predicate="!~* \"^${regex_lt}$\""
    pass_predicate="~* \"^${regex_lt}$\""
    ;;
  le)
    _sr_is_unsigned_int "$val" || return 1
    local regex_le="$(_sr_numeric_regex_le "$val")"
    display_value="0"
    fail_predicate="!~* \"^${regex_le}$\""
    pass_predicate="~* \"^${regex_le}$\""
    ;;
  exists)
    fail_predicate="= \"\""
    pass_predicate="!= \"\""
    ;;
  not_exists)
    fail_predicate="!= \"\""
    pass_predicate="= \"\""
    ;;
  *)
    printf '%s%s%s%s%s' "" "$sep" "" "$sep" ""
    return 1
    ;;
  esac
  printf '%s%s%s%s%s' "$display_value" "$sep" "$fail_predicate" "$sep" "$pass_predicate"
}

# Map field types to Nginx variables and user-facing labels
