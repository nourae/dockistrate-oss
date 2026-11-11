#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES=(
  http_cidr_allow_exact_deny
  http_exact_allow_cidr_deny
  http_same_address
  http_overlapping_cidrs
  http_allow_all
  http_explicit_deny_all
  http_nonoverlap
  http_disabled_deny
  http_insertion_order
  stream_cidr_allow_exact_deny
  stream_exact_allow_cidr_deny
  stream_same_address_scopes
  stream_overlapping_cidrs
  stream_allow_all
  stream_explicit_deny_all
  stream_nonoverlap
  stream_disabled_deny
  stream_insertion_order
  allow_policy_preserved
  http_custom_status
  http_l3_override
  http_inherited_lists
  http_explicit_child_list
  http_stable_variables
)

if [ "$#" -eq 0 ]; then
  failed=0
  for test_case in "${CASES[@]}"; do
    if "$BASH" "${BASH_SOURCE[0]}" --case "$test_case"; then
      printf '[tests] PASS: ACL deny precedence %s\n' "$test_case"
    else
      printf '[tests] FAIL: ACL deny precedence %s\n' "$test_case" >&2
      failed=1
    fi
  done
  [ "$failed" -ne 0 ] || printf 'ACL deny precedence checks passed (%s cases).\n' "${#CASES[@]}"
  exit "$failed"
fi
[ "$#" -eq 2 ] && [ "$1" = --case ] || exit 2
case_found=false
for test_case in "${CASES[@]}"; do
  [ "$test_case" != "$2" ] || case_found=true
done
[ "$case_found" = true ] || exit 2

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/security_rules.sh
source "$ROOT_DIR/lib/security_rules.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_acl_precedence.XXXXXX")"
trap 'status=$?; if [ "$status" -eq 0 ]; then rm -rf "$TMP_ROOT"; else printf "[tests] Failed ACL fixture retained: %s\n" "$TMP_ROOT" >&2; fi' EXIT
BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
SECURITY_IP_RULES_DB="$CONFIG_DIR/security_ip_rules.csv"
OUTPUT="$TMP_ROOT/include"
ACL_POLICY=deny
ACL_STATUS=403
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" \
  'backend,primary.example.com,127.0.0.1:8080,dockistrate-net,,,,,,,,,,,,,,,,,' >"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
  'alias,alias.example.com,primary.example.com' \
  'dedicated,dedicated.example.com,primary.example.com' >"$BACKEND_ALIASES_FILE"
printf '%s\n' "$STATE_BACKEND_ACL_POLICIES_HEADER" >"$BACKEND_ACL_POLICY_FILE"
printf '%s\n' "$STATE_BACKEND_ACL_STATUSES_HEADER" >"$BACKEND_ACL_STATUS_FILE"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  exit 1
}
function docker() { fail_test 'This ACL renderer fixture must not call Docker'; }
function write_rules() {
  printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" "$@" >"$SECURITY_IP_RULES_DB"
}
function render_acl() {
  local mode="$1" domain="${2:-primary.example.com}"
  if [ "$mode" = http ]; then
    _build_security_ip_for_domain "$domain" >"$OUTPUT" || fail_test "HTTP render failed for $domain"
  else
    _build_security_ip_stream_for_domain "$domain" >"$OUTPUT" || fail_test "Stream render failed for $domain"
  fi
}
function assert_contains() {
  grep -Fq -- "$1" "$OUTPUT" || fail_test "Missing '$1'"
}
function assert_absent() {
  if grep -Fq -- "$1" "$OUTPUT"; then fail_test "Unexpected '$1'"; fi
}
function assert_before() {
  local earlier="" later=""
  earlier="$(awk -v needle="$1" '$0 == needle { print NR; exit }' "$OUTPUT")"
  later="$(awk -v needle="$2" '$0 == needle { print NR; exit }' "$OUTPUT")"
  [ -n "$earlier" ] && [ -n "$later" ] && [ "$earlier" -lt "$later" ] || fail_test "Expected '$1' before '$2'"
}

# Independently interpret only Nginx access-module allow/deny directives in
# their emitted order. This is not an HTTP rewrite-phase emulator: custom
# status and real-IP return guards have separate assertions below, and live
# request tests cover the complete Nginx execution path.
function expect_access_decision() {
  local client="$1" expected="$2" actual=""
  actual="$(awk -v client="$client" '
    function address(value, octets) {
      split(value, octets, /[.]/)
      return ((octets[1] * 256 + octets[2]) * 256 + octets[3]) * 256 + octets[4]
    }
    function matches(rule, parts, count, size) {
      if (rule == "all") return 1
      count = split(rule, parts, "/")
      if (count == 1) return address(client) == address(rule)
      size = 2 ^ (32 - parts[2])
      return int(address(client) / size) == int(address(parts[1]) / size)
    }
    ($1 == "allow" || $1 == "deny") && NF == 2 {
      rule = $2
      sub(/;$/, "", rule)
      if (matches(rule)) { print $1; found = 1; exit }
    }
    END { if (!found) print "implicit-allow" }
  ' "$OUTPUT")" || fail_test 'Unable to evaluate generated access directives'
  [ "$actual" = "$expected" ] || fail_test "Access decision for $client: expected $expected, got $actual"
}

function check_cidr_allow_exact_deny() {
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '1,primary.example.com,l7,deny,192.0.2.9,403'
  render_acl "$1"
  expect_access_decision 192.0.2.9 deny
  expect_access_decision 192.0.2.10 allow
  expect_access_decision 198.51.100.10 deny
}
function check_exact_allow_cidr_deny() {
  write_rules '1,primary.example.com,l7,allow,192.0.2.9,' \
    '1,primary.example.com,l7,deny,192.0.2.0/24,403'
  render_acl "$1"
  expect_access_decision 192.0.2.9 deny
  expect_access_decision 192.0.2.10 deny
}
function check_same_address() {
  local mode="$1" scope="${2:-l7}"
  write_rules "1,primary.example.com,$scope,allow,192.0.2.9," \
    "1,primary.example.com,$scope,deny,192.0.2.9,403"
  render_acl "$mode"
  expect_access_decision 192.0.2.9 deny
}
function check_overlapping_cidrs() {
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '1,primary.example.com,l7,deny,192.0.2.128/25,403'
  render_acl "$1"
  expect_access_decision 192.0.2.128 deny
  expect_access_decision 192.0.2.255 deny
  expect_access_decision 192.0.2.127 allow
}
function check_allow_all() {
  write_rules '1,primary.example.com,l7,allow,0.0.0.0/0,' \
    '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '1,primary.example.com,l7,deny,192.0.2.9,403'
  render_acl "$1"
  expect_access_decision 192.0.2.9 deny
  expect_access_decision 192.0.2.10 allow
  expect_access_decision 198.51.100.10 allow
  assert_before 'allow all;' 'deny all;'
}
function check_explicit_deny_all() {
  write_rules '1,primary.example.com,l7,allow,192.0.2.9,' \
    '1,primary.example.com,l7,allow,0.0.0.0/0,' \
    '1,primary.example.com,l7,deny,0.0.0.0/0,403'
  render_acl "$1"
  expect_access_decision 192.0.2.9 deny
  expect_access_decision 198.51.100.10 deny
  # The persisted explicit deny-all must win; the generated fallback remains
  # last so it does not break ordinary non-overlapping whitelist entries.
  assert_before 'deny 0.0.0.0/0;' 'allow 192.0.2.9;'
  assert_before 'allow all;' 'deny all;'
}
function check_nonoverlap() {
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '1,primary.example.com,l7,deny,198.51.100.9,403'
  render_acl "$1"
  expect_access_decision 192.0.2.9 allow
  expect_access_decision 198.51.100.9 deny
  expect_access_decision 203.0.113.9 deny
}
function check_disabled_deny() {
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '0,primary.example.com,l7,deny,192.0.2.9,403'
  render_acl "$1"
  expect_access_decision 192.0.2.9 allow
  assert_absent 'deny 192.0.2.9;'
}
function check_insertion_order() {
  local mode="$1" first="" second=""
  first='1,primary.example.com,l7,allow,192.0.2.0/24,'
  second='1,primary.example.com,l7,deny,192.0.2.9,403'
  write_rules "$first" "$second"
  render_acl "$mode"
  expect_access_decision 192.0.2.9 deny
  awk '$1 == "allow" || $1 == "deny"' "$OUTPUT" >"$TMP_ROOT/first-order"
  write_rules "$second" "$first"
  render_acl "$mode"
  expect_access_decision 192.0.2.9 deny
  awk '$1 == "allow" || $1 == "deny"' "$OUTPUT" >"$TMP_ROOT/second-order"
  cmp -s "$TMP_ROOT/first-order" "$TMP_ROOT/second-order" || fail_test 'Row insertion order changed access decisions'
}

function http_cidr_allow_exact_deny() { check_cidr_allow_exact_deny http; }
function http_exact_allow_cidr_deny() { check_exact_allow_cidr_deny http; }
function http_same_address() { check_same_address http; }
function http_overlapping_cidrs() { check_overlapping_cidrs http; }
function http_allow_all() { check_allow_all http; }
function http_explicit_deny_all() { check_explicit_deny_all http; }
function http_nonoverlap() { check_nonoverlap http; }
function http_disabled_deny() { check_disabled_deny http; }
function http_insertion_order() { check_insertion_order http; }
function stream_cidr_allow_exact_deny() { check_cidr_allow_exact_deny stream; }
function stream_exact_allow_cidr_deny() { check_exact_allow_cidr_deny stream; }
function stream_overlapping_cidrs() { check_overlapping_cidrs stream; }
function stream_allow_all() { check_allow_all stream; }
function stream_explicit_deny_all() { check_explicit_deny_all stream; }
function stream_nonoverlap() { check_nonoverlap stream; }
function stream_disabled_deny() { check_disabled_deny stream; }
function stream_insertion_order() { check_insertion_order stream; }
function stream_same_address_scopes() {
  local scope
  for scope in l7 l3 both; do check_same_address stream "$scope"; done
}

function allow_policy_preserved() {
  local mode
  ACL_POLICY=allow
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '1,primary.example.com,l7,deny,192.0.2.9,403'
  for mode in http stream; do
    render_acl "$mode"
    expect_access_decision 192.0.2.9 deny
    expect_access_decision 192.0.2.10 implicit-allow
    expect_access_decision 198.51.100.10 implicit-allow
    assert_absent 'allow 192.0.2.0/24;'
    assert_absent 'deny all;'
  done
}

function http_custom_status() {
  local default_status var=""
  for default_status in 403 444; do
    ACL_STATUS="$default_status"
    write_rules '1,primary.example.com,l7,allow,192.0.2.9,' \
      '1,primary.example.com,l7,deny,192.0.2.9,451'
    render_acl http
    assert_contains 'if ($remote_addr = 192.0.2.9) { return 451; }'
    if [ "$default_status" = 403 ]; then
      assert_contains 'allow 192.0.2.9;'
    else
      var="$(awk '$1 == "set" && $2 ~ /^\$sr_[0-9]+_l7_allow$/ { print $2; exit }' "$OUTPUT")"
      [ -n "$var" ] || fail_test 'Missing custom-status L7 allow variable'
      assert_contains "if (\$remote_addr = 192.0.2.9) { set $var 1; }"
      assert_before 'if ($remote_addr = 192.0.2.9) { return 451; }' "if ($var = 0) { return 444; }"
    fi
  done
  write_rules '1,primary.example.com,l7,allow,0.0.0.0/0,' \
    '1,primary.example.com,l7,deny,192.0.2.9,403'
  render_acl http
  assert_contains 'deny 192.0.2.9;'
  var="$(awk '$1 == "set" && $2 ~ /^\$sr_[0-9]+_l7_allow$/ { print $2; exit }' "$OUTPUT")"
  assert_contains "set $var 1;"
  assert_before 'deny 192.0.2.9;' "if ($var = 0) { return 444; }"
}

function http_l3_override() {
  local scope var=""
  for scope in l3 both; do
    write_rules "1,primary.example.com,$scope,allow,198.51.100.9," \
      "1,primary.example.com,$scope,deny,198.51.100.9,429"
    render_acl http
    var="$(awk '$1 == "set" && $2 ~ /^\$sr_[0-9]+_l3_allow$/ { print $2; exit }' "$OUTPUT")"
    [ -n "$var" ] || fail_test 'Missing L3 allow variable'
    assert_contains "if (\$realip_remote_addr = 198.51.100.9) { set $var 1; }"
    assert_before 'if ($realip_remote_addr = 198.51.100.9) { return 429; }' "if ($var = 0) { return 403; }"
    if [ "$scope" = l3 ]; then
      assert_absent 'if ($remote_addr = 198.51.100.9) { return 429; }'
    else
      assert_contains 'if ($remote_addr = 198.51.100.9) { return 429; }'
    fi
  done
}

function http_inherited_lists() {
  local domain
  ACL_POLICY=allow
  printf '%s\n' 'primary.example.com,deny' >>"$BACKEND_ACL_POLICY_FILE"
  write_rules '1,primary.example.com,l7,allow,192.0.2.0/24,' \
    '1,primary.example.com,l7,deny,192.0.2.9,403'
  for domain in alias.example.com dedicated.example.com; do
    render_acl http "$domain"
    expect_access_decision 192.0.2.9 deny
    expect_access_decision 192.0.2.10 allow
    expect_access_decision 198.51.100.10 deny
  done
  printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" \
    'dedicated.example.com,yes,no,yes,yes,yes' >"$CONFIG_DIR/dedicated_host_inheritance.csv"
  render_acl http dedicated.example.com
  expect_access_decision 192.0.2.9 implicit-allow
  assert_absent 'deny 192.0.2.9;'
}

function http_explicit_child_list() {
  local domain
  for domain in alias.example.com dedicated.example.com; do
    write_rules '1,primary.example.com,l7,deny,192.0.2.0/24,403' \
      "1,$domain,l7,allow,192.0.2.0/24," \
      "1,$domain,l7,deny,192.0.2.9,403"
    render_acl http "$domain"
    expect_access_decision 192.0.2.9 deny
    expect_access_decision 192.0.2.10 allow
    assert_absent 'deny 192.0.2.0/24;'
  done
}

function http_stable_variables() {
  local domain first="" previous="" names="" label="" final_label=""
  ACL_STATUS=451
  write_rules '1,primary.example.com,both,allow,192.0.2.9,'
  render_acl http primary.example.com
  first="$(cat "$OUTPUT")"
  render_acl http PRIMARY.EXAMPLE.COM
  [ "$first" = "$(cat "$OUTPUT")" ] || fail_test 'Domain normalization changed ACL output'
  # Rendering another host must not influence either layer of this host's ACL.
  render_acl http dedicated.example.com
  render_acl http primary.example.com
  [ "$first" = "$(cat "$OUTPUT")" ] || fail_test 'Repeated ACL rendering changed output'
  # Alias and dedicated hosts need separate names from their inherited parent.
  # Include long hosts to ensure variable names stay within default Nginx limits.
  label="$(printf '%063d' 0 | tr 0 a)"
  final_label="$(printf '%061d' 0 | tr 0 b)"
  for domain in primary.example.com alias.example.com dedicated.example.com a-b.example.com a.b-example.com "$label.$label.$label.$final_label"; do
    render_acl http "$domain"
    names="$(awk '$1 == "set" { print $2 }' "$OUTPUT")"
    awk '$1 == "set" && (length($2) > 48 || $2 !~ /^\$sr_[0-9_]+_l[37]_allow$/) { exit 1 }' "$OUTPUT" || fail_test 'ACL variable must have a bounded, Nginx-safe name'
    [ "$(printf '%s\n' "$names" | sort -u | wc -l | tr -d '[:space:]')" = 2 ] || fail_test 'L7 and L3 variables must be distinct'
    if [ -n "$previous" ] && printf '%s\n' "$names" | grep -Fxq -f "$TMP_ROOT/previous-variables"; then
      fail_test 'Different hosts must have distinct ACL variables'
    fi
    previous="${previous}${names}"$'\n'
    printf '%s' "$previous" >"$TMP_ROOT/previous-variables"
  done
  (
    # Force the existing checksum allocator's collision branch, independently
    # of the host names and of the request-rule renderer's reservation state.
    function _sr_hash_rule_seed() { printf '%s' sr_0000000001; }
    SECURITY_IP_DIR="$CONFIG_DIR/nginx_conf/conf.d/security_ip"
    SECURITY_IP_STREAM_DIR="$CONFIG_DIR/nginx_conf/stream/security_ip"
    write_rules '1,primary.example.com,both,allow,192.0.2.9,' \
      '1,alias.example.com,both,allow,192.0.2.10,'
    SR_RULE_VARS_EMITTED=sr_0000000001
    build_security_ip_includes || fail_test 'Collision-aware ACL build failed'
    [ "$SR_RULE_VARS_EMITTED" = sr_0000000001 ] || fail_test 'ACL build changed request-rule reservations'
    first="$(find "$SECURITY_IP_DIR" -type f -exec cksum {} \; | sort)"
    names="$(awk '$1 == "set" { print $2 }' "$SECURITY_IP_DIR"/*.inc)"
    [ "$(printf '%s\n' "$names" | sort -u | wc -l | tr -d '[:space:]')" = 6 ] || fail_test 'Hash collisions must not share host/layer variables'
    build_security_ip_includes || fail_test 'Repeated collision-aware ACL build failed'
    [ "$first" = "$(find "$SECURITY_IP_DIR" -type f -exec cksum {} \; | sort)" ] || fail_test 'Hash collision allocation changed between renders'
  )
}

"$2"
