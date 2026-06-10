#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"

function assert_eq() {
  local actual="${1:-}" expected="${2:-}" msg="${3:-assertion failed}"
  if [ "$actual" != "$expected" ]; then
    echo "[Error] ${msg}: expected '${expected}', got '${actual}'." >&2
    exit 1
  fi
}

rule_choice='10|AND int-sec.example.com (n=3),header:User-Agent contains IntBot,method equals GET,path starts_with /interactive'
v=""
l=""
cli_choice_line_to_value_label "$rule_choice" v l
assert_eq "$v" "10" "pipe choice value must remain numeric id"
assert_eq "$l" "AND int-sec.example.com (n=3),header:User-Agent contains IntBot,method equals GET,path starts_with /interactive" "pipe choice label must preserve commas"

csv_choice='and,AND (all conditions)'
v=""
l=""
cli_choice_line_to_value_label "$csv_choice" v l
assert_eq "$v" "and" "csv choice value should parse as first field"
assert_eq "$l" "AND (all conditions)" "csv choice label should parse as second field"

csv_choice_with_pipe='not_matches,"Not Matches — regex does not match. Example: header X-Agent not_matches (curl|wget)"'
v=""
l=""
cli_choice_line_to_value_label "$csv_choice_with_pipe" v l
assert_eq "$v" "not_matches" "csv choice value should not be truncated when label contains pipe"
assert_eq "$l" "Not Matches — regex does not match. Example: header X-Agent not_matches (curl|wget)" "csv choice label should preserve pipe characters"

# Guard against output-var collisions with parser internal variable names.
parsed_value=""
parsed_label=""
cli_choice_line_to_value_label "port|Port (server)" parsed_value parsed_label
assert_eq "$parsed_value" "port" "output value must populate even with parsed_value var name"
assert_eq "$parsed_label" "Port (server)" "output label must populate even with parsed_label var name"

echo "cli_choice_line_to_value_label pipe-with-commas guard checks passed."
