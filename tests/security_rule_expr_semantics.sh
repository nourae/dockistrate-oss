#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_strings.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_numeric.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_selectors.sh"

function assert_expr_triplet() {
  local cond="$1" val="$2" expected_default="$3" expected_fail="$4" expected_pass="$5"
  local actual sep=$'\x1f' actual_default="" actual_fail="" actual_pass=""

  actual="$(_sr_exprs "$cond" "$val")"
  IFS=$sep read -r actual_default actual_fail actual_pass <<<"$actual"

  if [ "$actual_default" != "$expected_default" ] || [ "$actual_fail" != "$expected_fail" ] || [ "$actual_pass" != "$expected_pass" ]; then
    printf '[Error] Unexpected triplet for %s.\nExpected: [%s] [%s] [%s]\nActual:   [%s] [%s] [%s]\n' \
      "$cond" "$expected_default" "$expected_fail" "$expected_pass" "$actual_default" "$actual_fail" "$actual_pass" >&2
    exit 1
  fi
}

assert_expr_triplet "equals" "secret" "secret" '!= "secret"' '= "secret"'
assert_expr_triplet "not_equals" "secret" "" '= "secret"' '!= "secret"'
assert_expr_triplet "contains" "a.b" "a.b" '!~* "a\.b"' '~* "a\.b"'
assert_expr_triplet "not_contains" "a.b" "" '~* "a\.b"' '!~* "a\.b"'
assert_expr_triplet "starts_with" "pre." "pre." '!~* "^pre\."' '~* "^pre\."'
assert_expr_triplet "not_starts_with" "pre." "" '~* "^pre\."' '!~* "^pre\."'
assert_expr_triplet "ends_with" ".json" ".json" '!~* "\.json$"' '~* "\.json$"'
assert_expr_triplet "not_ends_with" ".json" "" '~* "\.json$"' '!~* "\.json$"'
assert_expr_triplet "matches" "(curl|wget)" "(curl|wget)" '!~* "((curl|wget))"' '~* "((curl|wget))"'
assert_expr_triplet "not_matches" "(curl|wget)" "" '~* "((curl|wget))"' '!~* "((curl|wget))"'

echo "Security rule expression semantics checks passed."
