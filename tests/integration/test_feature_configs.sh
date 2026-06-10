#!/usr/bin/env bash

# shellcheck source=tests/integration/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

SHUNIT2_TIMING="${SHUNIT2_TIMING:-true}"
SHUNIT2_TIMING_TOP="${SHUNIT2_TIMING_TOP:-20}"

FEATURE_CONFIGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "${FEATURE_CONFIGS_DIR}/test_feature_configs.d" ]; then
  for test_file in "${FEATURE_CONFIGS_DIR}/test_feature_configs.d"/*.sh; do
    # shellcheck disable=SC1090
    . "$test_file"
  done
fi

function suite() {
  integration_shunit_suite_add_tests "integration-feature-configs"
}

# shellcheck disable=SC1090
. "${SHUNIT2}"
