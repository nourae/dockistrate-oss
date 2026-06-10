#!/usr/bin/env bash

function integration_shunit_fatal() {
  local message="${1:-integration suite setup failed}"
  if declare -F _shunit_fatal >/dev/null 2>&1; then
    _shunit_fatal "$message"
  fi

  echo "[tests] Error: ${message}" >&2
  return 1
}

function integration_shunit_is_non_negative_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

function integration_shunit_suite_add_tests() {
  local suite_name="${1:-integration}"
  local test_names="" test_name="" total_tests=0 selected_tests=0 ordinal=0
  local shard_total="${TEST_SHARD_TOTAL:-}" shard_index="${TEST_SHARD_INDEX:-}"
  local shard_enabled=false selected_for_shard=0

  test_names="$(declare -F | awk '{print $3}' | grep '^test_' | sort || true)"
  for test_name in $test_names; do
    total_tests=$((total_tests + 1))
  done
  command [ "$total_tests" -gt 0 ] ||
    integration_shunit_fatal "${suite_name}: no shunit test functions discovered" ||
    return 1

  if command [ -n "$shard_total" ] || command [ -n "$shard_index" ]; then
    shard_enabled=true
    integration_shunit_is_non_negative_integer "$shard_total" ||
      integration_shunit_fatal "${suite_name}: TEST_SHARD_TOTAL must be a positive integer" ||
      return 1
    integration_shunit_is_non_negative_integer "$shard_index" ||
      integration_shunit_fatal "${suite_name}: TEST_SHARD_INDEX must be a non-negative integer" ||
      return 1
    command [ "$shard_total" -gt 0 ] ||
      integration_shunit_fatal "${suite_name}: TEST_SHARD_TOTAL must be greater than 0" ||
      return 1
    command [ "$shard_index" -lt "$shard_total" ] ||
      integration_shunit_fatal "${suite_name}: TEST_SHARD_INDEX must be less than TEST_SHARD_TOTAL" ||
      return 1
  fi

  ordinal=0
  for test_name in $test_names; do
    selected_for_shard=1
    if $shard_enabled; then
      selected_for_shard=0
      if command [ $((ordinal % shard_total)) -eq "$shard_index" ]; then
        selected_for_shard=1
      fi
    fi

    if command [ "$selected_for_shard" -eq 1 ]; then
      suite_addTest "$test_name"
      selected_tests=$((selected_tests + 1))
    fi
    ordinal=$((ordinal + 1))
  done

  command [ "$selected_tests" -gt 0 ] ||
    integration_shunit_fatal "${suite_name}: shard selected no tests" ||
    return 1

  if $shard_enabled; then
    echo "[tests] ${suite_name}: selected ${selected_tests}/${total_tests} tests for shard ${shard_index} of ${shard_total}"
  else
    echo "[tests] ${suite_name}: selected ${selected_tests}/${total_tests} tests (unsharded)"
  fi
}
