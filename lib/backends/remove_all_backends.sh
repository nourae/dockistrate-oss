# shellcheck shell=bash
function remove_all_backends() {
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Info] No backends configured."
    return
  fi

  local removed=0
  local backends="" line="" line_no=0 dom=""
  local -a domains=()
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
    [ -n "${STATE_BP_DOMAIN:-}" ] || continue
    backends+="${STATE_BP_DOMAIN}"$'\n'
  done <"$BACKEND_PORTS_FILE"

  # Collect first so nested confirmation prompts retain the caller's stdin.
  while IFS= read -r dom; do
    [ -n "$dom" ] || continue
    domains+=("$dom")
  done < <(printf '%s' "$backends" | awk 'NF > 0' | sort -u)

  if [ "${#domains[@]}" -eq 0 ]; then
    echo "[Info] No backends configured."
    return
  fi

  for dom in "${domains[@]}"; do
    remove_backend "$dom" || return 1
    if ! backend_exists "$dom"; then
      removed=$((removed + 1))
    fi
  done

  if [ "$removed" -eq 0 ]; then
    echo "[Info] No backends removed."
  else
    echo "[Info] Removed ${removed} backends."
    create_backup "" "RemoveAllBackends"
  fi
}
