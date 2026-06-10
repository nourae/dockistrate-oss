#!/usr/bin/env bash

test_update_log_field_rejects_out_of_range_id() {
  local log_fields_file="${CONFIG_DIR}/access_log_fields.csv"
  local snapshot
  snapshot="$(mktemp "${TMPDIR:-/tmp}/dockistrate.log_fields.XXXXXX")"
  run_dockistrate list-log-fields >/dev/null
  cp "$log_fields_file" "$snapshot"

  local output status
  output="$(run_dockistrate update-log-field 99 '$time_local')"
  status=$?

  assertTrue "update-log-field should fail for out-of-range id" "[ $status -ne 0 ]"
  assertStringContains "error output should mention range" "out of range" "$output"
  assertTrue "log fields file should remain unchanged" "cmp -s \"$snapshot\" \"$log_fields_file\""

  rm -f "$snapshot"
}
