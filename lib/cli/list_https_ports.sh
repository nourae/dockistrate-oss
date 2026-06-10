# shellcheck shell=bash

# Return newline-separated list of HTTPS ports (default 443 plus custom mappings)
function list_https_ports() {
  local ports=(443)
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local line="" line_no=0
    local type="" custom_port="" protocol=""
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      type="${STATE_BP_RECORD_TYPE:-}"
      custom_port="${STATE_BP_LISTEN_PORT:-}"
      protocol="${STATE_BP_PROTOCOL:-}"
      if [[ "$type" == "port" && "$protocol" == "https" && "$custom_port" =~ ^[0-9]+$ ]]; then
        ports+=("$custom_port")
      fi
    done <"$BACKEND_PORTS_FILE"
  fi
  printf '%s\n' "${ports[@]}" | sort -u
}
