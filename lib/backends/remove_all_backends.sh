# shellcheck shell=bash
function remove_all_backends() {
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Info] No backends configured."
    return
  fi

  local removed=0
  local backends="" line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
    [ -n "${STATE_BP_DOMAIN:-}" ] || continue
    backends+="${STATE_BP_DOMAIN}"$'\n'
  done <"$BACKEND_PORTS_FILE"

  while read -r dom; do
    [ -n "$dom" ] || continue
    remove_backend "$dom"
    removed=$((removed + 1))
  done < <(printf '%s' "$backends" | awk 'NF > 0' | sort -u)

  if [ "$removed" -eq 0 ]; then
    echo "[Info] No backends configured."
  else
    echo "[Info] Removed ${removed} backends."
    create_backup "" "RemoveAllBackends"
  fi
}
