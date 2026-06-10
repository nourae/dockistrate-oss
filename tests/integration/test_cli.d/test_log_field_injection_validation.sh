#!/usr/bin/env bash

test_add_log_field_rejects_injection_attempts() {
  local output status

  # Test single quote injection attempt
  output="$(run_dockistrate add-log-field "'; malicious_directive;" 2>&1)"
  status=$?
  assertNotEquals "add-log-field should reject single quotes" 0 $status
  assertStringContains "error should mention invalid field" "Invalid log field" "$output"

  # Test semicolon injection attempt
  output="$(run_dockistrate add-log-field '; worker_processes 100' 2>&1)"
  status=$?
  assertNotEquals "add-log-field should reject semicolons" 0 $status
  assertStringContains "error should mention invalid field" "Invalid log field" "$output"

  # Test valid field is accepted
  output="$(run_dockistrate add-log-field '$http_x_test' 2>&1)"
  status=$?
  assertEquals "add-log-field should accept valid nginx variable" 0 $status
}

test_update_log_field_rejects_injection_attempts() {
  local fields_file="${CONFIG_DIR}/access_log_fields.csv"
  local output status

  # First add a valid field to update
  run_dockistrate add-log-field '$test_field' >/dev/null 2>&1

  # Test single quote injection attempt in update
  output="$(run_dockistrate update-log-field 1 "'; malicious_directive;" 2>&1)"
  status=$?
  assertNotEquals "update-log-field should reject single quotes" 0 $status
  assertStringContains "error should mention invalid field" "Invalid log field" "$output"

  # Test semicolon injection attempt in update
  output="$(run_dockistrate update-log-field 1 "; worker_processes 100" 2>&1)"
  status=$?
  assertNotEquals "update-log-field should reject semicolons" 0 $status
  assertStringContains "error should mention invalid field" "Invalid log field" "$output"
}
