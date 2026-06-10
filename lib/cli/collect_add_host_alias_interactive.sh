# shellcheck shell=bash

# Guided flow for adding a host alias with enforced backend selection and non-empty alias
function collect_add_host_alias_interactive() {
  local has_http_https="false"
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
      case "${STATE_BP_PROTOCOL:-}" in
      http | https)
        has_http_https="true"
        break
        ;;
      esac
    done <"$BACKEND_PORTS_FILE"
  fi
  if [ "$has_http_https" != "true" ]; then
    echo "[Info] No backends with HTTP/HTTPS ports configured. Add a backend with an HTTP/HTTPS port first." >&2
    read -rp "Press Enter to continue..." _
    return 1
  fi

  local domain="" alias="" step=0
  while true; do
    case "$step" in
    0)
      if ! choose_alias_backend domain; then
        return 1
      fi
      step=1
      ;;
    1)
      local idx
      if ! choose_option idx "Alias for ${domain} (blank=Back):" "Enter alias" "Back"; then
        return 1
      fi
      if [ "$idx" -eq 1 ]; then
        step=0
        continue
      fi
      read_with_editing "Alias (blank=Back): " alias
      if is_back_input "$alias" || [ -z "$alias" ]; then
        step=0
        continue
      fi
      if ! is_valid_domain "$alias"; then
        echo "[Error] Invalid alias. Please enter a valid domain name." >&2
        continue
      fi
      if backend_exists "$alias"; then
        echo "[Error] Alias '${alias}' is already a backend domain." >&2
        continue
      fi
      if alias_exists "$alias"; then
        echo "[Error] Alias '${alias}' already exists." >&2
        continue
      fi
      step=2
      ;;
    esac
    ((step >= 2)) && break
  done

  SELECTED_CMD="add-host-alias"
  SELECTED_ARGS=("$alias" "$domain")
  return 0
}
