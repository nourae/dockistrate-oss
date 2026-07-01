# shellcheck shell=bash

function list_headers() {
  if [ ! -f "$CUSTOM_HEADERS_FILE" ] || [ ! -s "$CUSTOM_HEADERS_FILE" ]; then
    echo "[None]"
    return
  fi

  if ! csv_require_header "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER"; then
    echo "[None]"
    return
  fi

  local line="" line_no=0 printed=false
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_CUSTOM_HEADERS_COLS" ] || continue
    printed=true
    echo "${CSV_FIELDS[0]} ${CSV_FIELDS[1]} $(operator_value_for_display header_value "${CSV_FIELDS[2]}")"
  done <"$CUSTOM_HEADERS_FILE"

  if [ "$printed" = false ]; then
    echo "[None]"
  fi
}

# Add or update a backend specific header
# Args: <domain> <request|response> <name> <value>
