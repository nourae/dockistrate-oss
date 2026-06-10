#!/usr/bin/env bash

read_rules_file() {
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq 6 ] || continue
    if [ -n "${CSV_FIELDS[5]}" ]; then
      printf '%s,%s,%s,%s,%s\n' "${CSV_FIELDS[1]}" "${CSV_FIELDS[2]}" "${CSV_FIELDS[3]}" "${CSV_FIELDS[4]}" "${CSV_FIELDS[5]}"
    else
      printf '%s,%s,%s,%s\n' "${CSV_FIELDS[1]}" "${CSV_FIELDS[2]}" "${CSV_FIELDS[3]}" "${CSV_FIELDS[4]}"
    fi
  done <"$SECURITY_IP_RULES_DB"
}
