#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils/state_helpers.sh
source "$ROOT_DIR/lib/utils/state_helpers.sh"
# shellcheck source=../lib/security_rules/common.sh
source "$ROOT_DIR/lib/security_rules/common.sh"
# shellcheck source=../lib/security_rules/_sr_strings.sh
source "$ROOT_DIR/lib/security_rules/_sr_strings.sh"
# shellcheck source=../lib/security_rules/_sr_numeric.sh
source "$ROOT_DIR/lib/security_rules/_sr_numeric.sh"
# shellcheck source=../lib/security_rules/_sr_selectors.sh
source "$ROOT_DIR/lib/security_rules/_sr_selectors.sh"
# shellcheck source=../lib/security_rules/_sr_db.sh
source "$ROOT_DIR/lib/security_rules/_sr_db.sh"
# shellcheck source=../lib/security_rules/_sr_builders.sh
source "$ROOT_DIR/lib/security_rules/_sr_builders.sh"

failures=0
function assert_contains() {
  local output="$1" expected="$2" message="$3"
  if [[ "$output" != *"$expected"* ]]; then
    printf '[FAIL] %s\nMissing: %s\n' "$message" "$expected" >&2
    failures=$((failures + 1))
  fi
}

function assert_not_contains() {
  local output="$1" unexpected="$2" message="$3"
  if [[ "$output" == *"$unexpected"* ]]; then
    printf '[FAIL] %s\nUnexpected: %s\n' "$message" "$unexpected" >&2
    failures=$((failures + 1))
  fi
}

function assert_rule_scope() {
  local output="$1" mode="$2"
  assert_contains "$output" 'if ($dockistrate_security_identity = primary.example.com)' \
    "$mode must use the trusted serving identity"
  assert_not_contains "$output" 'if ($host = primary.example.com)' \
    "$mode applicability must not depend on the request Host"
  assert_contains "$output" 'if ($sr_000000_m = 1) { set $sr_000000_fail 1; }' \
    "$mode must still scope rejection to its configured backend"
}

SR_RULE_COUNTER=0
single="$(_generate_security_rule_line primary.example.com header:X-Single equals pass 451)"
assert_rule_scope "$single" single
assert_contains "$single" 'if ($http_x_single = "pass") { set $sr_000000_p1 1; }' 'single predicate is retained'
assert_contains "$single" 'return 451;' 'single status is retained'

SR_RULE_COUNTER=0
or_rule="$(_generate_security_rule_multi_line or primary.example.com 452 - auto header:X-Left equals pass header:X-Right equals pass)"
assert_rule_scope "$or_rule" OR
assert_contains "$or_rule" 'if ($http_x_left = "pass") { set $sr_000000_pass 1; }' 'OR left success is retained'
assert_contains "$or_rule" 'if ($http_x_right = "pass") { set $sr_000000_pass 1; }' 'OR right success is retained'
assert_contains "$or_rule" 'return 452;' 'OR status is retained'

SR_RULE_COUNTER=0
and_rule="$(_generate_security_rule_multi_line and primary.example.com 453 - auto header:X-Left equals pass header:X-Right equals pass)"
assert_rule_scope "$and_rule" AND
assert_contains "$and_rule" 'if ($sr_000000_tmp = "11") { set $sr_000000_fail 0; }' 'AND still requires both predicates'
assert_contains "$and_rule" 'return 453;' 'AND status is retained'

# A host predicate intentionally examines the requested name, unlike the rule scope.
SR_RULE_COUNTER=0
host_rule="$(_generate_security_rule_line primary.example.com host equals alias.example.com 454)"
assert_rule_scope "$host_rule" 'Host-selector single'
assert_contains "$host_rule" 'if ($host = "alias.example.com") { set $sr_000000_p1 1; }' \
  'the Host selector must retain the real request host'

SR_RULE_COUNTER=0
host_tls_rule="$(_generate_security_rule_multi_line and primary.example.com 455 - auto host equals alias.example.com tls_sni equals alias.example.com)"
assert_rule_scope "$host_tls_rule" 'Host/SNI AND'
assert_contains "$host_tls_rule" 'if ($host = "alias.example.com") { set $sr_000000_p1 1; }' 'multi-condition Host selector retains request Host'
assert_contains "$host_tls_rule" 'if ($ssl_server_name = "alias.example.com") { set $sr_000000_p2 1; }' 'TLS SNI selector retains the handshake server name'

# Exercise recipient selection using real persisted state, without launching Docker.
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/security_rules.sh
source "$ROOT_DIR/lib/security_rules.sh"
TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_rule_identity.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT
BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
NGINX_HTTP_CONF_DIR="$CONFIG_DIR/nginx_conf/conf.d"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_DB="$CONFIG_DIR/security_ip_rules.csv"
SECURITY_RULES_INC="$NGINX_HTTP_CONF_DIR/security_rules.inc"
OUTPUT="$TMP_ROOT/output"
mkdir -p "$CONFIG_DIR"
printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_DB"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" \
  'backend,primary.example.com,127.0.0.1:8080,dockistrate-net,,,,,,,,,,,,,,,,,' \
  'backend,other.example.com,127.0.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,' >"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
  'alias,alias.example.com,primary.example.com' \
  'alias,split.example.com,primary.example.com' \
  'dedicated,inherit.example.com,primary.example.com' \
  'dedicated,independent.example.com,primary.example.com' \
  'alias,other-alias.example.com,other.example.com' >"$BACKEND_ALIASES_FILE"
printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" \
  'independent.example.com,yes,yes,no,yes,yes' >"$CONFIG_DIR/dedicated_host_inheritance.csv"
printf '%s\n' "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" \
  'primary.example.com,451' 'alias.example.com,429' \
  'inherit.example.com,452' 'independent.example.com,430' >"$BACKEND_SECURITY_RULE_STATUS_FILE"

function assert_value() {
  local expected="$1" message="$2" actual
  shift 2
  actual="$("$@")" || { printf '[FAIL] %s lookup failed\n' "$message" >&2; exit 1; }
  if [ "$expected" != "$actual" ]; then
    printf '[FAIL] %s: expected [%s], got [%s]\n' "$message" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}
function assert_rejected() {
  local message="$1"
  shift
  if "$@" >"$OUTPUT" 2>&1; then
    printf '[FAIL] %s was accepted\n' "$message" >&2
    failures=$((failures + 1))
  fi
}

recipients="$(_sr_rule_recipients primary.example.com | sort)"
assert_value "$(printf '%s\n' primary.example.com alias.example.com split.example.com inherit.example.com | sort)" \
  'only aliases and inheriting dedicated hosts receive backend rules' printf '%s' "$recipients"
assert_value independent.example.com 'own rules remain scoped to an independent dedicated host' \
  _sr_rule_recipients independent.example.com
assert_value alias.example.com 'own persisted alias rules do not expand to sibling hosts' \
  _sr_rule_recipients alias.example.com
assert_value 429 'explicit alias default status wins' get_backend_security_rule_status alias.example.com
assert_value 451 'alias default status inherits primary' get_backend_security_rule_status split.example.com
assert_value 452 'explicit dedicated default status wins' get_backend_security_rule_status inherit.example.com

identity_lines="$(_sr_identity_directives primary.example.com 'alias.example.com split.example.com')"
assert_contains "$identity_lines" 'set $dockistrate_security_identity "primary.example.com";' 'primary identity defaults to its configured backend'
assert_contains "$identity_lines" 'if ($host = alias.example.com) { set $dockistrate_security_identity "alias.example.com"; }' 'registered aliases select their compiled rule recipients'
assert_not_contains "$identity_lines" 'other-alias.example.com' 'another backend must not influence the identity whitelist'
assert_rejected 'unregistered identity' _sr_identity_directives missing.example.com
assert_rejected 'identity injection' _sr_identity_directives 'bad; return 200;'
assert_rejected 'alias injection' _sr_identity_directives primary.example.com 'alias.example.com;'
assert_rejected 'cross-backend alias mapping' _sr_identity_directives primary.example.com other-alias.example.com
assert_rejected 'unregistered rule recipient' _sr_rule_recipients missing.example.com

cp "$BACKEND_ALIASES_FILE" "$TMP_ROOT/aliases.saved"
for invalid_row in \
  'alias,alias.example.com,primary.example.com' \
  'dedicated,alias.example.com,primary.example.com' \
  'alias,orphan.example.com,missing.example.com'; do
  cp "$TMP_ROOT/aliases.saved" "$BACKEND_ALIASES_FILE"
  printf '%s\n' "$invalid_row" >>"$BACKEND_ALIASES_FILE"
  assert_rejected "late duplicate, conflicting or orphaned topology: $invalid_row" \
    _sr_rule_recipients primary.example.com
done
mv "$TMP_ROOT/aliases.saved" "$BACKEND_ALIASES_FILE"

cp "$CONFIG_DIR/dedicated_host_inheritance.csv" "$TMP_ROOT/inheritance.saved"
printf '%s\n' 'inherit.example.com,yes,yes,invalid,yes,yes' >>"$CONFIG_DIR/dedicated_host_inheritance.csv"
assert_rejected 'malformed inheritance' _sr_rule_recipients primary.example.com
mv "$TMP_ROOT/inheritance.saved" "$CONFIG_DIR/dedicated_host_inheritance.csv"
# Missing inheritance state has the documented default of yes.
rm "$CONFIG_DIR/dedicated_host_inheritance.csv"
recipients="$(_sr_rule_recipients primary.example.com)"
assert_contains "$recipients" independent.example.com 'absent inheritance file defaults to enabled'
printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" \
  'independent.example.com,yes,yes,no,yes,yes' >"$CONFIG_DIR/dedicated_host_inheritance.csv"

# Only the unrelated IP include builder is stubbed; request-rule parsing,
# recipient expansion, status lookup and Nginx rule generation stay real.
function build_security_ip_includes() { :; }
{
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER"
  _sr_write_db_line 1 primary.example.com single '' 1 header X-Single equals pass
  _sr_write_db_line 1 primary.example.com or 460 2 header X-Or-A equals pass header X-Or-B equals pass
  _sr_write_db_line 1 primary.example.com and 461 2 header X-And-A equals pass header X-And-B equals pass
  _sr_write_db_line 1 independent.example.com single '' 1 header X-Own equals pass
  _sr_write_db_line 1 inherit.example.com single '' 1 header X-Own-Inherited equals pass
  _sr_write_db_line 1 other.example.com single 462 1 header X-Other equals pass
} >"$SECURITY_RULES_DB"
build_security_rules_inc
rules="$(cat "$SECURITY_RULES_INC")"
for recipient in primary.example.com alias.example.com split.example.com inherit.example.com; do
  recipient_rules="$(grep -F "if (\$dockistrate_security_identity = $recipient)" "$SECURITY_RULES_INC")"
  assert_contains "$recipient_rules" '$http_x_single' "$recipient receives the single rule"
  assert_contains "$recipient_rules" '$http_x_or_a' "$recipient receives the OR rule"
  assert_contains "$recipient_rules" '$http_x_and_b' "$recipient receives the AND rule"
  assert_contains "$recipient_rules" 'return 460;' "$recipient preserves explicit OR status"
  assert_contains "$recipient_rules" 'return 461;' "$recipient preserves explicit AND status"
  assert_not_contains "$recipient_rules" '$http_x_other' "$recipient excludes the other backend rule"
done
for status_pair in primary.example.com:451 alias.example.com:429 split.example.com:451 inherit.example.com:452; do
  recipient="${status_pair%:*}" expected_status="${status_pair##*:}"
  rule="$(grep -F "if (\$dockistrate_security_identity = $recipient)" "$SECURITY_RULES_INC" | grep -F '$http_x_single')"
  assert_contains "$rule" "return $expected_status;" "$recipient uses its effective default status"
done
independent_rules="$(grep -F 'if ($dockistrate_security_identity = independent.example.com)' "$SECURITY_RULES_INC")"
assert_contains "$independent_rules" '$http_x_own' 'independent dedicated host keeps its own persisted rule'
assert_contains "$independent_rules" 'return 430;' 'own rule uses dedicated default status'
assert_not_contains "$independent_rules" '$http_x_single' 'inheritance=no excludes backend request rules'
inherited_rules="$(grep -F 'if ($dockistrate_security_identity = inherit.example.com)' "$SECURITY_RULES_INC")"
assert_contains "$inherited_rules" '$http_x_own_inherited' 'host-owned rules add to inherited rules'
assert_value 16 'each row expands only to its authorized recipients' awk '/dockistrate_security_identity/ { count++ } END { print count }' "$SECURITY_RULES_INC"
variable_count="$(sed -n 's/.*set \$\(sr_[[:alnum:]_]*\)_m 0;.*/\1/p' "$SECURITY_RULES_INC" | sort -u | awk 'END { print NR }')"
assert_value 16 'recipient expansions have independent variable identities' printf '%s' "$variable_count"
first_render="$rules"
build_security_rules_inc
assert_value "$first_render" 'repeated rendering is byte stable' cat "$SECURITY_RULES_INC"

# Disabled orphan rows remain inert; enabling the same row must fail closed.
_sr_write_db_line 0 removed.example.com single '' 1 header X-Orphan equals pass >>"$SECURITY_RULES_DB"
build_security_rules_inc
assert_value "$first_render" 'disabled orphan rules do not change active rules' cat "$SECURITY_RULES_INC"
_sr_write_db_line 1 removed.example.com single '' 1 header X-Orphan equals pass >>"$SECURITY_RULES_DB"
assert_rejected 'enabled rule with an unresolved identity' build_security_rules_inc

# The same accepted identities must be discoverable in interactive choices and completion.
# shellcheck source=../lib/cli/get_arg_choices.sh
source "$ROOT_DIR/lib/cli/get_arg_choices.sh"
# shellcheck source=../lib/cli/arg_choices_misc.sh
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"
# shellcheck source=../lib/cli/arg_choices_security.sh
source "$ROOT_DIR/lib/cli/arg_choices_security.sh"
expected_choices="$(printf '%s\n' primary.example.com other.example.com alias.example.com split.example.com \
  inherit.example.com independent.example.com other-alias.example.com | sort)"
assert_value "$expected_choices" 'interactive status override choices include aliases and dedicated hosts' \
  get_arg_choices set-backend-security-rule-status domain
assert_value "$(printf '%s\n' primary.example.com alias.example.com inherit.example.com independent.example.com | sort)" \
  'interactive removal choices include host-owned status overrides' \
  get_arg_choices remove-backend-security-rule-status domain
__dockistrate_completion_handlers=()
COMPREPLY=()
cur="" prev="" cword=2
# shellcheck source=../completion/commands/__dockistrate_backend_domains.sh
source "$ROOT_DIR/completion/commands/__dockistrate_backend_domains.sh"
# shellcheck source=../completion/commands/__dockistrate_complete_backend_domains.sh
source "$ROOT_DIR/completion/commands/__dockistrate_complete_backend_domains.sh"
# shellcheck source=../completion/commands/_dockistrate_complete_backend_domain_commands.sh
source "$ROOT_DIR/completion/commands/_dockistrate_complete_backend_domain_commands.sh"
_dockistrate_complete_backend_domain_commands set-backend-security-rule-status
assert_value "$expected_choices" 'status completion includes every accepted identity' \
  printf '%s\n' "${COMPREPLY[@]}"

if [ "$failures" -ne 0 ]; then
  printf '[FAIL] %s request-security identity assertions failed.\n' "$failures" >&2
  exit 1
fi
printf 'Request-security compiler identity checks passed.\n'
