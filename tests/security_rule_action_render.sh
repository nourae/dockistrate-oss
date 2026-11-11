#!/usr/bin/env bash
# Fixture variables are consumed by the real security renderer.
# shellcheck disable=SC2034
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils security_rules; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/security-actions.XXXXXXXX")"
TEST_ROOT="$(cd -P "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT
BASE_DIR="$TEST_ROOT" STATE_DIR="$TEST_ROOT/state" CONFIG_DIR="$TEST_ROOT/state/config"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
SECURITY_RULES_INC="$CONFIG_DIR/nginx_conf/conf.d/security_rules.inc"
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" \
  'backend,primary.example.com,127.0.0.1:8080,dockistrate-net,,,,,,,,,,,,,,,,,' >"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
  'alias,alias.example.com,primary.example.com' \
  'dedicated,inherited.example.com,primary.example.com' \
  'dedicated,independent.example.com,primary.example.com' >"$BACKEND_ALIASES_FILE"
printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" \
  'independent.example.com,yes,yes,no,yes,yes' >"$CONFIG_DIR/dedicated_host_inheritance.csv"
printf '%s\n' "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" >"$BACKEND_SECURITY_RULE_STATUS_FILE"
# ACLs have their own tested builder. Keep request-row parsing, inheritance,
# effective status, stable variable allocation and action rendering real.
function build_security_ip_includes() { :; }
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function contains() { [[ "$1" == *"$2"* ]] || fail_test "Missing $2"; }
function excludes() { [[ "$1" != *"$2"* ]] || fail_test "Unexpected $2"; }
function rule() {
  local action="$1" domain="$2" name="$3" code="$4"
  _sr_write_db_line_with_action "$action" 1 "$domain" single "$code" 1 header "$name" equals yes
}
{
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER"
  rule allow primary.example.com X-Allow 450
  rule block alias.example.com X-Alias-Block 451
  rule require primary.example.com X-Require 452
  rule block primary.example.com X-Block 453
  rule require alias.example.com X-Alias-Require 454
  rule allow independent.example.com X-Own-Allow 455
  rule block independent.example.com X-Own-Block 456
  _sr_write_db_line_with_action block 0 removed.example.com single 457 1 header X-Disabled equals yes
} >"$SECURITY_RULES_DB"
build_security_rules_inc
[ "$(head -n 1 "$SECURITY_RULES_INC")" = 'set $dockistrate_security_decision 0;' ] || fail_test 'Include does not reset its decision latch'

function assert_host_order() {
  local host="$1" expected="$2" actual=""
  actual="$(grep -F "if (\$dockistrate_security_identity = $host)" "$SECURITY_RULES_INC" | sed -n 's/.*if (\$http_\([a-z_]*\) = "yes").*/\1/p')"
  [ "$actual" = "$expected" ] || fail_test "Wrong phase/global order for $host: $actual"
}
assert_host_order primary.example.com "$(printf '%s\n' x_require x_allow x_block)"
assert_host_order alias.example.com "$(printf '%s\n' x_require x_alias_require x_allow x_alias_block x_block)"
assert_host_order inherited.example.com "$(printf '%s\n' x_require x_allow x_block)"
assert_host_order independent.example.com "$(printf '%s\n' x_own_allow x_own_block)"
excludes "$(cat "$SECURITY_RULES_INC")" '$http_x_disabled'
first="$(cat "$SECURITY_RULES_INC")"
build_security_rules_inc
[ "$(cat "$SECURITY_RULES_INC")" = "$first" ] || fail_test 'Repeated action rendering is unstable'

allow="$(grep -F 'if ($dockistrate_security_identity = primary.example.com)' "$SECURITY_RULES_INC" | grep -F '$http_x_allow')"
contains "$allow" 'if ($http_x_allow = "yes")'
contains "$allow" '_selected "$dockistrate_security_decision:'
contains "$allow" '_selected = "0:1:1") { set $dockistrate_security_decision 1; }'
for bypass in 'return ' 'break;' 'satisfy ' 'allow all;'; do excludes "$allow" "$bypass"; done
block="$(grep -F 'if ($dockistrate_security_identity = primary.example.com)' "$SECURITY_RULES_INC" | grep -F '$http_x_block')"
contains "$block" 'if ($http_x_block = "yes")'
contains "$block" '_selected = "0:1:1") {'
contains "$block" 'return 453;'
require="$(grep -F 'if ($dockistrate_security_identity = primary.example.com)' "$SECURITY_RULES_INC" | grep -F '$http_x_require')"
contains "$require" '_fail = 1) {'
contains "$require" 'return 452;'
excludes "$require" '$dockistrate_security_decision'

# Preserve positive predicate truth, combination modes and escaping for decisions.
SR_RULE_COUNTER=0
and_line="$(_generate_security_decision_line block and primary.example.com 458 'blocked "reason"' edge '' header:X-A equals a header:X-B not_equals b)"
contains "$and_line" 'if ($http_x_a = "a") { set $sr_000000_p1 1; }'
contains "$and_line" 'if ($http_x_b != "b") { set $sr_000000_p2 1; }'
contains "$and_line" 'set $sr_000000_tmp "$sr_000000_p1$sr_000000_p2"; if ($sr_000000_tmp = "11") { set $sr_000000_pass 1; }'
contains "$and_line" 'set $dockistrate_rule_reason "blocked \"reason\"";'
or_line="$(_generate_security_decision_line allow or primary.example.com 459 - auto '' header:X-A equals a header:X-B not_equals b)"
contains "$or_line" 'if ($http_x_a = "a") { set $sr_000000_pass 1; }'
contains "$or_line" 'if ($http_x_b != "b") { set $sr_000000_pass 1; }'
excludes "$or_line" 'return '
args=()
for count in 1 2 3 4 5 6 7 8 9 10; do args+=("header:X-$count" equals yes); done
ten="$(_generate_security_decision_line block and primary.example.com 460 - auto '' "${args[@]}")"
contains "$ten" 'if ($sr_000000_tmp = "1111111111") { set $sr_000000_pass 1; }'
if _generate_security_decision_line unknown single primary.example.com 460 - auto '' header:X equals yes >"$TEST_ROOT/error" 2>&1; then fail_test 'Unknown action rendered'; fi

# An empty action is a historical Require and remains independent of decisions.
line="$(rule require primary.example.com X-Legacy 461)"
csv_parse_line "$line"
CSV_FIELDS[47]=''
{ printf '%s\n' "$STATE_SECURITY_RULES_HEADER"; csv_join_row "${CSV_FIELDS[@]}"; } >"$SECURITY_RULES_DB"
build_security_rules_inc
contains "$(cat "$SECURITY_RULES_INC")" 'return 461;'
excludes "$(tail -n +2 "$SECURITY_RULES_INC")" '$dockistrate_security_decision'
# Invalid actions fail closed even on a disabled row.
csv_parse_line "$line"
CSV_FIELDS[0]=0 CSV_FIELDS[47]=unknown
{ printf '%s\n' "$STATE_SECURITY_RULES_HEADER"; csv_join_row "${CSV_FIELDS[@]}"; } >"$SECURITY_RULES_DB"
if build_security_rules_inc >"$TEST_ROOT/error" 2>&1; then fail_test 'Invalid persisted action rendered'; fi
grep -q 'action must be require, block or allow' "$TEST_ROOT/error" || fail_test 'Invalid action error was not explicit'
printf '[PASS] Require phase, ordered Block/Allow, identity inheritance and latch-only Allow rendering\n'
