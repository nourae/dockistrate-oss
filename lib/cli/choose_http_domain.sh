# shellcheck shell=bash

# Prompt for a backend domain and store the selection in the given variable
function choose_http_domain() {
  local __var="$1"
  require_valid_var_name "$__var" || return 1
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Info] No backends configured." >&2
    return 1
  fi
  local list=""
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
    [ -n "${STATE_BP_DOMAIN:-}" ] || continue
    list+="${STATE_BP_DOMAIN}"$'\n'
  done <"$BACKEND_PORTS_FILE"
  list="$(printf '%s' "$list" | awk 'NF > 0' | sort -u)"
  [ -z "$list" ] && {
    echo "[Info] No backends configured." >&2
    return 1
  }
  read_lines_into_array domains "$list"
  local idx
  if ! choose_option idx "Select backend:" "${domains[@]}" "Back"; then
    return 1
  fi
  ((idx == ${#domains[@]})) && return 1
  printf -v "$__var" '%s' "${domains[$idx]}"
}
