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

function _sr_exprs() {
  # Return d\x1f f\x1f p via stdout to avoid nameref/local scope issues on Bash 3
  local cond="$1" val="$2"
  local d f p sep=$'\x1f'
  case "$cond" in
  secret_header | equals)
    d="${val}"
    f="!= \"${val}\""
    p="= \"${val}\""
    ;;
  not_equals)
    d=""
    f="= \"${val}\""
    p="!= \"${val}\""
    ;;
  contains)
    local re_contains="$(_sr_escape_regex_literal "${val}")"
    d="${val}"
    f="!~* \"${re_contains}\""
    p="~* \"${re_contains}\""
    ;;
  not_contains)
    local re_not_contains="$(_sr_escape_regex_literal "${val}")"
    d=""
    f="~* \"${re_not_contains}\""
    p="!~* \"${re_not_contains}\""
    ;;
  starts_with)
    local re_starts="$(_sr_escape_regex_literal "${val}")"
    d="${val}"
    f="!~* \"^${re_starts}\""
    p="~* \"^${re_starts}\""
    ;;
  not_starts_with)
    local re_not_starts="$(_sr_escape_regex_literal "${val}")"
    d=""
    f="~* \"^${re_not_starts}\""
    p="!~* \"^${re_not_starts}\""
    ;;
  ends_with)
    local re_ends="$(_sr_escape_regex_literal "${val}")"
    d="${val}"
    f="!~* \"${re_ends}$\""
    p="~* \"${re_ends}$\""
    ;;
  not_ends_with)
    local re_not_ends="$(_sr_escape_regex_literal "${val}")"
    d=""
    f="~* \"${re_not_ends}$\""
    p="!~* \"${re_not_ends}$\""
    ;;
  matches)
    d="${val}"
    f="!~* \"(${val})\""
    p="~* \"(${val})\""
    ;;
  not_matches)
    d=""
    f="~* \"(${val})\""
    p="!~* \"(${val})\""
    ;;
  in)
    local -a _sr_in_parts=()
    local _sr_in_joined="" _sr_in_piece
    IFS=',' read -r -a _sr_in_parts <<<"$val"
    for _sr_in_piece in "${_sr_in_parts[@]}"; do
      local escaped_piece
      escaped_piece="$(_sr_escape_regex_literal "${_sr_in_piece}")"
      if [ -z "${_sr_in_joined}" ]; then
        _sr_in_joined="${escaped_piece}"
      else
        _sr_in_joined+="|${escaped_piece}"
      fi
    done
    d=""
    f="~* (${_sr_in_joined})"
    p="!~* (${_sr_in_joined})"
    ;;
  not_in)
    local -a _sr_not_in_parts=()
    local _sr_not_in_joined="" _sr_not_in_piece
    IFS=',' read -r -a _sr_not_in_parts <<<"$val"
    for _sr_not_in_piece in "${_sr_not_in_parts[@]}"; do
      local escaped_not_in_piece
      escaped_not_in_piece="$(_sr_escape_regex_literal "${_sr_not_in_piece}")"
      if [ -z "${_sr_not_in_joined}" ]; then
        _sr_not_in_joined="${escaped_not_in_piece}"
      else
        _sr_not_in_joined+="|${escaped_not_in_piece}"
      fi
    done
    d="${val}"
    f="!~* (${_sr_not_in_joined})"
    p="~* (${_sr_not_in_joined})"
    ;;
  gt)
    _sr_is_unsigned_int "$val" || return 1
    local regex_gt="$(_sr_numeric_regex_ge "$(_sr_numeric_inc "$val")")"
    d="0"
    f="~* \"^${regex_gt}$\""
    p="!~* \"^${regex_gt}$\""
    ;;
  ge)
    _sr_is_unsigned_int "$val" || return 1
    local regex_ge="$(_sr_numeric_regex_ge "$val")"
    d="0"
    f="~* \"^${regex_ge}$\""
    p="!~* \"^${regex_ge}$\""
    ;;
  lt)
    _sr_is_unsigned_int "$val" || return 1
    local regex_ge_lt="$(_sr_numeric_regex_ge "$val")"
    d="0"
    f="!~* \"^${regex_ge_lt}$\""
    p="~* \"^${regex_ge_lt}$\""
    ;;
  le)
    _sr_is_unsigned_int "$val" || return 1
    local inc="$(_sr_numeric_inc "$val")"
    local regex_ge_le="$(_sr_numeric_regex_ge "$inc")"
    d="0"
    f="!~* \"^${regex_ge_le}$\""
    p="~* \"^${regex_ge_le}$\""
    ;;
  exists)
    d=""
    f="!= \"\""
    p="= \"\""
    ;;
  not_exists)
    d=""
    f="= \"\""
    p="!= \"\""
    ;;
  *)
    printf '%s%s%s%s%s' "" "$sep" "" "$sep" ""
    return 1
    ;;
  esac
  printf '%s%s%s%s%s' "$d" "$sep" "$f" "$sep" "$p"
}

# Map field types to Nginx variables and user-facing labels
