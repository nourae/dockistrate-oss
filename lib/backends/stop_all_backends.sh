# shellcheck shell=bash
function stop_all_backends() {
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Info] No backends configured."
    return
  fi

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

  printf '%s' "$backends" | awk 'NF > 0' | sort -u | while read -r dom; do
    local cname="backend-$(sanitize_domain_name "$dom")"
    if container_exists "$cname"; then
      docker stop "$cname" >/dev/null
      echo "[Info] Stopped $cname."
      log_msg "Stopped backend container $cname."
    fi
  done

  create_backup "" "StopAllBackends"
}
