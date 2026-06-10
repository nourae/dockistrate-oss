#!/usr/bin/env bash

test_add_log_field_position_handling() {
  local fields_file="${CONFIG_DIR}/access_log_fields.csv"

  local in_range_field='$http_x_positioned'
  local output status
  output="$(run_dockistrate add-log-field "$in_range_field" 2)"
  status=$?
  assertEquals "add-log-field should succeed for in-range position" 0 $status

  local inserted_line
  inserted_line="$(sed -n '3p' "$fields_file")"
  assertEquals "field should be inserted at requested position" "$in_range_field" "$inserted_line"

  local appended_field='$http_x_appended'
  output="$(run_dockistrate add-log-field "$appended_field" 999)"
  status=$?
  assertEquals "add-log-field should append when position exceeds count" 0 $status

  local last_line
  last_line="$(tail -n 1 "$fields_file" | tr -d '\r' | sed -e 's/^"//' -e 's/"$//')"
  assertEquals "field should be appended when position exceeds count" "$appended_field" "$last_line"

  local invalid_field='$http_x_invalid'
  output="$(run_dockistrate add-log-field "$invalid_field" 0)"
  status=$?
  assertTrue "add-log-field should fail for positions less than 1" "[ $status -ne 0 ]"
  assertStringContains "error message should explain invalid position" "position must be 1 or greater" "$output"
}
