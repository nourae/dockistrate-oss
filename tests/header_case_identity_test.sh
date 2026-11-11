#!/usr/bin/env bash
# Fixture paths and state are consumed by sourced production functions.
# Literal backslashes and Nginx variables below are intentional test data.
# shellcheck disable=SC2034,SC1091,SC1003,SC2016
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/headers.sh"
source "$ROOT_DIR/lib/nginx/status.sh"
VISIBILITY_POLICY=full
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/header_case_identity.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
CUSTOM_HEADERS_FILE="$TEST_WORK/custom_headers.csv"
BACKEND_HEADERS_FILE="$TEST_WORK/backend_headers.csv"
NGINX_HTTP_CONF_DIR="$TEST_WORK/generated"
mkdir -p "$NGINX_HTTP_CONF_DIR"
global_conf="$NGINX_HTTP_CONF_DIR/custom_headers.conf"
backend_conf="$NGINX_HTTP_CONF_DIR/backend_headers.conf"
maps_conf="$NGINX_HTTP_CONF_DIR/backend_header_maps.conf"
failures=0

function check_equal() {
  if [ "$1" != "$2" ]; then
    printf '[FAIL] %s: expected <%s>, got <%s>\n' "$3" "$1" "$2" >&2
    failures=$((failures + 1))
  fi
}
function count_line() { grep -Fxc -- "$1" "$2" || true; }
function map_rows() {
  awk -v variable="$1" '
    $0 == "map $dockistrate_backend_header_key $" variable " {" { selected=1; next }
    selected && $0 == "}" { selected=0; next }
    selected { print }
  ' "$maps_conf"
}
function count_map_line() { map_rows "$1" | grep -Fxc -- "$2" || true; }
function list_dedicated_hosts_for_backend() {
  [ "$1" != primary.example.com ] || printf 'dedicated.example.com\ninherited.example.com\nseparate.example.com\n'
}
function get_dedicated_host_inheritance() {
  if [ "$1" = separate.example.com ]; then printf 'no\n'; else printf 'yes\n'; fi
}

# Global files may reorder named columns. Identical variants are a generated
# view concern: keep their original bytes/spelling in the editable file.
printf 'header_value,header_name,header_type\nglobal,X-Global,response\nglobal,x-global,response\nrequest,X-GLOBAL,request\n' >"$CUSTOM_HEADERS_FILE"
{
  printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER"
  csv_join_row primary.example.com response X-Trace primary-response
  csv_join_row primary.example.com response x-trace primary-response
  csv_join_row primary.example.com request X-Trace primary-request
  csv_join_row other.example.com response x-trace other-response
  csv_join_row dedicated.example.com response x-TRACE dedicated-response
  csv_join_row primary.example.com response X-Literal 'C:\tmp\n; quote \"; } server { listen 19999; } #; trailing \'
  csv_join_row primary.example.com response x-literal 'C:\tmp\n; quote \"; } server { listen 19999; } #; trailing \'
} >"$BACKEND_HEADERS_FILE"
cp "$CUSTOM_HEADERS_FILE" "$TEST_WORK/global-before"
cp "$BACKEND_HEADERS_FILE" "$TEST_WORK/backend-before"
_build_header_files
check_equal 1 "$(count_line '    add_header X-Global "global" always;' "$global_conf")" 'global response spelling'
check_equal 2 "$(wc -l <"$global_conf" | tr -d ' ')" 'one global directive per request/response identity'
check_equal 1 "$(count_line 'map $dockistrate_backend_header_key $backend_header_x_trace {' "$maps_conf")" 'one response map across capitalization and owners'
check_equal 1 "$(count_line 'map $dockistrate_backend_header_key $backend_req_x_trace {' "$maps_conf")" 'separate request map'
check_equal 1 "$(count_line '    add_header X-Trace $backend_header_x_trace always;' "$backend_conf")" 'first stored spelling is retained'
check_equal 3 "$(wc -l <"$backend_conf" | tr -d ' ')" 'one backend directive per logical name/type'
check_equal 1 "$(count_map_line backend_header_x_trace '    primary.example.com "primary-response";')" 'coalesced primary value'
check_equal 1 "$(count_map_line backend_header_x_trace '    other.example.com "other-response";')" 'different owner retains own value'
check_equal 1 "$(count_map_line backend_header_x_trace '    dedicated.example.com "dedicated-response";')" 'case-insensitive dedicated override'
check_equal 0 "$(count_map_line backend_header_x_trace '    dedicated.example.com "primary-response";')" 'inheritance cannot override explicit variant'
check_equal 1 "$(count_map_line backend_header_x_trace '    inherited.example.com "primary-response";')" 'dedicated inheritance'
check_equal 0 "$(count_map_line backend_header_x_trace '    separate.example.com "primary-response";')" 'disabled inheritance'
check_equal 1 "$(count_map_line backend_req_x_trace '    dedicated.example.com "primary-request";')" 'response override leaves request inheritance intact'
# Handwritten expected escaping must not reuse the implementation's helper.
check_equal 1 "$(count_map_line backend_header_x_literal '    primary.example.com "C:\\tmp\\n; quote \\\"; } server { listen 19999; } #; trailing \\";')" 'literal escaping survives coalescence'
cmp -s "$CUSTOM_HEADERS_FILE" "$TEST_WORK/global-before" || check_equal unchanged changed 'global source bytes'
cmp -s "$BACKEND_HEADERS_FILE" "$TEST_WORK/backend-before" || check_equal unchanged changed 'backend source bytes'
list_headers >"$TEST_WORK/global-list"
list_backend_headers primary.example.com >"$TEST_WORK/backend-list"
_status_print_global_headers >"$TEST_WORK/global-status"
_status_print_backend_header_overrides >"$TEST_WORK/backend-status"
check_equal 2 "$(wc -l <"$TEST_WORK/global-list" | tr -d ' ')" 'global listing coalesces identity'
check_equal 3 "$(wc -l <"$TEST_WORK/backend-list" | tr -d ' ')" 'backend listing coalesces identity within requested owner'
check_equal 1 "$(count_line '  X-Global: global' "$TEST_WORK/global-status")" 'status retains first spelling once'
check_equal 4 "$(wc -l <"$TEST_WORK/global-status" | tr -d ' ')" 'status coalesces case variants'
check_equal 1 "$(grep -c 'primary.example.com.*response.*X-Trace.*primary-response' "$TEST_WORK/backend-status" || true)" 'backend status coalesces case variants'
check_equal 8 "$(wc -l <"$TEST_WORK/backend-status" | tr -d ' ')" 'backend status preserves distinct owners and types'
check_equal global "$(get_global_header_value x-GLOBAL response)" 'global lookup ignores capitalization'
check_equal primary-request "$(get_backend_header_value PRIMARY.EXAMPLE.COM x-TRACE request)" 'backend lookup ignores capitalization'

# Build twice in the same shell to detect stale map storage from prior renders.
{
  printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER"
  csv_join_row primary.example.com response x-trace replacement
} >"$BACKEND_HEADERS_FILE"
_build_header_files
check_equal 1 "$(count_map_line backend_header_x_trace '    primary.example.com "replacement";')" 'second render replaces prior value'
check_equal 0 "$(count_map_line backend_header_x_trace '    primary.example.com "primary-response";')" 'second render drops stale value'
check_equal 0 "$(count_line 'map $dockistrate_backend_header_key $backend_req_x_trace {' "$maps_conf")" 'second render drops removed request map'

# Empty strings are values, so an empty first row must still conflict with a
# nonempty variant. A missing lookup and a present empty value are not aliases.
printf '%s\n' "$STATE_CUSTOM_HEADERS_HEADER" >"$CUSTOM_HEADERS_FILE"
{
  printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER"
  csv_join_row primary.example.com response X-Conflict ''
  csv_join_row primary.example.com response x-conflict different
} >"$BACKEND_HEADERS_FILE"
if _build_header_files >"$TEST_WORK/error" 2>&1; then
  check_equal rejected accepted 'backend conflicting case variants'
else
  grep -Fq primary.example.com "$TEST_WORK/error" || check_equal owner missing 'conflict diagnostic owner'
  grep -Fq response "$TEST_WORK/error" || check_equal type missing 'conflict diagnostic scope'
  grep -Eq '(set|update|remove|add)-backend-header' "$TEST_WORK/error" || check_equal repair missing 'actionable backend conflict diagnostic'
fi
if _status_print_backend_header_overrides >"$TEST_WORK/value" 2>"$TEST_WORK/error"; then
  check_equal rejected accepted 'conflicting backend status'
fi
if list_backend_headers primary.example.com >"$TEST_WORK/value" 2>"$TEST_WORK/error"; then
  check_equal rejected accepted 'conflicting backend listing'
fi
if get_backend_header_value primary.example.com X-CONFLICT response >"$TEST_WORK/value" 2>"$TEST_WORK/error"; then
  check_equal rejected accepted 'conflicting backend lookup'
fi
printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER" >"$BACKEND_HEADERS_FILE"
{
  printf '%s\n' "$STATE_CUSTOM_HEADERS_HEADER"
  csv_join_row response X-Conflict first
  csv_join_row response x-conflict second
} >"$CUSTOM_HEADERS_FILE"
if _build_header_files >"$TEST_WORK/error" 2>&1; then check_equal rejected accepted 'global conflicting case variants'; fi
if get_global_header_value X-CONFLICT response >"$TEST_WORK/value" 2>"$TEST_WORK/error"; then check_equal rejected accepted 'conflicting global lookup'; fi

if list_headers >"$TEST_WORK/value" 2>"$TEST_WORK/error"; then check_equal rejected accepted 'conflicting global listing'; fi
if _status_print_global_headers >"$TEST_WORK/value" 2>"$TEST_WORK/error"; then check_equal rejected accepted 'conflicting global status'; fi

# Existing HSTS/CSP convenience commands share the same mutation identity.
# Isolate backup/transaction side effects here; command-level publication and
# rollback are exercised by domain_config_header_case_repair.sh.
function _config_begin_transaction_if_needed() { printf -v "$1" '%s' false; }
function _config_end_transaction_if_started() { :; }
function create_backup() { :; }
function update_nginx_config() { _build_header_files; }
function domain_exists() { [ "$1" = primary.example.com ]; }
for scope in global backend; do
  for kind in hsts csp; do
    case "$kind" in
    hsts) header_name=Strict-Transport-Security; lower_name=strict-transport-security ;;
    csp) header_name=Content-Security-Policy; lower_name=content-security-policy ;;
    esac
    printf '%s\n' "$STATE_CUSTOM_HEADERS_HEADER" >"$CUSTOM_HEADERS_FILE"
    printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER" >"$BACKEND_HEADERS_FILE"
    if [ "$scope" = global ]; then
      {
        csv_join_row response "$header_name" first
        csv_join_row response "$lower_name" second
        csv_join_row request "$lower_name" keep-request
      } >>"$CUSTOM_HEADERS_FILE"
      setter="set_$kind"
      "$setter" selected-value >"$TEST_WORK/wrapper-output"
      check_equal selected-value "$(get_global_header_value "$lower_name" response)" "$setter consolidates variants"
      "$setter" OfF >"$TEST_WORK/wrapper-output"
      check_equal '' "$(get_global_header_value "$lower_name" response)" "$setter off removes all variants"
      check_equal keep-request "$(get_global_header_value "$header_name" request)" "$setter leaves request scope alone"
    else
      {
        csv_join_row primary.example.com response "$header_name" first
        csv_join_row primary.example.com response "$lower_name" second
        csv_join_row primary.example.com request "$lower_name" keep-request
      } >>"$BACKEND_HEADERS_FILE"
      setter="set_backend_$kind"
      "$setter" PRIMARY.EXAMPLE.COM selected-value >"$TEST_WORK/wrapper-output"
      check_equal selected-value "$(get_backend_header_value primary.example.com "$lower_name" response)" "$setter consolidates variants"
      "$setter" primary.example.com OfF >"$TEST_WORK/wrapper-output"
      check_equal '' "$(get_backend_header_value primary.example.com "$lower_name" response)" "$setter off removes all variants"
      check_equal keep-request "$(get_backend_header_value primary.example.com "$header_name" request)" "$setter leaves request scope alone"
    fi
  done
done

[ "$failures" -eq 0 ] || exit 1
printf '[PASS] Header identity, owner/type scopes, inheritance, exact escaping, conflict diagnostics, and repeated rendering\n'
