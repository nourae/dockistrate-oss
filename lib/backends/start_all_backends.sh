# shellcheck shell=bash
function start_all_backends() {
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

  local dom="" cname="" id="" ids=""
  # Verify all targets before the first lifecycle operation.
  while IFS= read -r dom; do
    [ -n "$dom" ] || continue
    _backend_container_snapshot "$dom" || return 1
    ids+="$BACKEND_CONTAINER_ID|$dom"$'\n'
  done <<<"$backends"
  while IFS='|' read -r id dom; do
    [ -n "$id" ] || continue
    docker start "$id" >/dev/null || return 1
    cname="backend-$(sanitize_domain_name "$dom")"
    echo "[Info] Started $cname."
    log_msg "Started backend container $cname."
  done <<<"$ids"

  update_nginx_config || return 1
  create_backup "" "StartAllBackends"
}

# Stop all configured backend containers (HTTP and TCP)
