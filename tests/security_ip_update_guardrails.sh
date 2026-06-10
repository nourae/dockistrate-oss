#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHUNIT2="${ROOT_DIR}/tests/lib/shunit2"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"

TMP_ROOT=""
CONFIG_DIR=""
BACKEND_PORTS_FILE=""
SECURITY_IP_RULES_FILE=""
SECURITY_IP_RULES_DB=""
SEED_RULE_FILE=""

GUARDRAILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/security_ip_update_guardrails.d"
if [ -d "$GUARDRAILS_DIR" ]; then
  for guardrail_file in "$GUARDRAILS_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$guardrail_file"
  done
fi

function suite() {
  local test_names test_name
  test_names=$(declare -F | awk '{print $3}' | grep '^test_' | sort)
  for test_name in $test_names; do
    suite_addTest "$test_name"
  done
}

# shellcheck source=tests/lib/shunit2
. "$SHUNIT2"
