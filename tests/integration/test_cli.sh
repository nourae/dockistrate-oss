#!/usr/bin/env bash

# shellcheck source=tests/integration/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

SHUNIT2_TIMING="${SHUNIT2_TIMING:-true}"
SHUNIT2_TIMING_TOP="${SHUNIT2_TIMING_TOP:-20}"

TEST_CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "${TEST_CLI_DIR}/test_cli.d" ]; then
  for test_file in "${TEST_CLI_DIR}/test_cli.d"/*.sh; do
    # shellcheck disable=SC1090
    . "$test_file"
  done
fi

function suite() {
  integration_shunit_suite_add_tests "integration-cli"
}

# shellcheck disable=SC1090
. "${SHUNIT2}"
