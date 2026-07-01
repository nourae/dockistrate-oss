#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils/state_helpers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_strings.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_numeric.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_selectors.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_db.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_builders.sh"

function assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '[Error] %s\nMissing: %s\n' "$message" "$needle" >&2
    exit 1
  fi
}

function assert_not_contains() {
  local haystack="$1" needle="$2" message="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '[Error] %s\nUnexpected: %s\n' "$message" "$needle" >&2
    exit 1
  fi
}

SR_RULE_COUNTER=0
single_line="$(_generate_security_rule_line example.com header:X-S equals yes 403 "single denied" auto)"
assert_contains "$single_line" 'set $sr_000000_fail 0; if ($sr_000000_m = 1) { set $sr_000000_fail 1; }' "Single rules must initialize a host-gated fail marker"
assert_contains "$single_line" 'set $sr_000000_p1 0; if ($http_x_s = "yes") { set $sr_000000_p1 1; }' "Single rules must use the success predicate"
assert_contains "$single_line" 'if ($sr_000000_p1 = 1) { set $sr_000000_fail 0; }' "Single rules must clear failure when the predicate passes"
assert_contains "$single_line" 'if ($sr_000000_fail = 1) { set $dockistrate_rule_reason "single denied"; set $dockistrate_rule_loc "auto"; return 403; }' "Single rules must deny when the predicate fails"
assert_not_contains "$single_line" '$http_x_s != "yes"' "Single rules must not use the failure predicate for equals"

SR_RULE_COUNTER=0
and_line="$(_generate_security_rule_multi_line and example.com 403 "and denied" auto header:X-A equals a header:X-B not_equals b)"
assert_contains "$and_line" 'if ($http_x_a = "a") { set $sr_000000_p1 1; }' "AND rules must use the success predicate for equals"
assert_contains "$and_line" 'if ($http_x_b != "b") { set $sr_000000_p2 1; }' "AND rules must use the success predicate for not_equals"
assert_contains "$and_line" 'if ($sr_000000_m = 1) { set $sr_000000_fail 1; }' "AND rules must be host-gated before denying"
assert_contains "$and_line" 'if ($sr_000000_tmp = "11") { set $sr_000000_fail 0; }' "AND rules must clear failure only when all predicates pass"
assert_contains "$and_line" 'if ($sr_000000_fail = 1) { set $dockistrate_rule_reason "and denied"; set $dockistrate_rule_loc "auto"; return 403; }' "AND rules must deny when any predicate fails"
assert_not_contains "$and_line" '$http_x_a != "a"' "AND rules must not use the failure predicate for equals"
assert_not_contains "$and_line" '$http_x_b = "b"' "AND rules must not use the failure predicate for not_equals"

SR_RULE_COUNTER=0
or_line="$(_generate_security_rule_multi_line or example.com 429 "or denied" edge header:X-C equals c header:X-D equals d)"
assert_contains "$or_line" 'set $sr_000000_pass 0;' "OR rules must initialize the pass marker"
assert_contains "$or_line" 'if ($http_x_c = "c") { set $sr_000000_pass 1; }' "OR rules must use the success predicate for equals"
assert_contains "$or_line" 'if ($http_x_d = "d") { set $sr_000000_pass 1; }' "OR rules must allow any passing predicate to clear failure"
assert_contains "$or_line" 'if ($sr_000000_m = 1) { set $sr_000000_fail 1; } if ($sr_000000_pass = 1) { set $sr_000000_fail 0; }' "OR rules must deny only on the all-fail case"
assert_contains "$or_line" 'if ($sr_000000_fail = 1) { set $dockistrate_rule_reason "or denied"; set $dockistrate_rule_loc "edge"; return 429; }' "OR rules must return the configured status when all predicates fail"
assert_not_contains "$or_line" '$http_x_c != "c"' "OR rules must not use the failure predicate for equals"

echo "Security rule multi-condition mode semantics checks passed."
