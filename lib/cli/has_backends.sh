# shellcheck shell=bash

function has_backends() {
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    if [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ]; then
      return 0
    fi
  done <"$BACKEND_PORTS_FILE"
  return 1
}
