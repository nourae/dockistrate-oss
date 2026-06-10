#!/usr/bin/env bash

test_update_log_field_updates_entry() {
  local fields_file="${CONFIG_DIR}/access_log_fields.csv"

  run_dockistrate list-log-fields >/dev/null

  local new_field='$http_x_updated'
  local output status
  output="$(run_dockistrate update-log-field 1 "$new_field")"
  status=$?
  assertEquals "update-log-field should succeed" 0 $status

  local updated_line
  updated_line="$(sed -n '2p' "$fields_file" | tr -d '\r' | sed -e 's/^"//' -e 's/"$//')"
  assertEquals "field should be updated" "$new_field" "$updated_line"
}
