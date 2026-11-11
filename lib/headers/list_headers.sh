# shellcheck shell=bash

function list_headers() {
  if [ ! -e "$CUSTOM_HEADERS_FILE" ] && [ ! -L "$CUSTOM_HEADERS_FILE" ]; then
    echo "[None]"
    return
  fi

  local shared_records=""
  if ! shared_records="$(_header_records "$CUSTOM_HEADERS_FILE" global)"; then
    return 1
  fi

  local line="" line_no=0 printed=false
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_CUSTOM_HEADERS_COLS" ] || return 1
    printed=true
    echo "${CSV_FIELDS[0]} ${CSV_FIELDS[1]} $(operator_value_for_display header_value "${CSV_FIELDS[2]}")"
  done <<<"$shared_records"

  if [ "$printed" = false ]; then
    echo "[None]"
  fi
}

# Add or update a backend specific header
# Args: <domain> <request|response> <name> <value>
