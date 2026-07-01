# shellcheck shell=bash

function list_backend_headers() {
  local domain="${1:-}"
  domain="$(normalize_domain "$domain")"
  if [ ! -f "$BACKEND_HEADERS_FILE" ] || [ ! -s "$BACKEND_HEADERS_FILE" ]; then
    echo "[None]"
    return
  fi

  if ! csv_require_header "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER"; then
    echo "[None]"
    return
  fi

  local line="" line_no=0 printed=false
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_HEADERS_COLS" ] || continue
    if [ -n "$domain" ] && [ "${CSV_FIELDS[0]}" != "$domain" ]; then
      continue
    fi
    printed=true
    echo "${CSV_FIELDS[0]} ${CSV_FIELDS[1]} ${CSV_FIELDS[2]} $(operator_value_for_display header_value "${CSV_FIELDS[3]}")"
  done <"$BACKEND_HEADERS_FILE"

  if [ "$printed" = false ]; then
    echo "[None]"
  fi
}

# Fetch current global header value for convenience defaults
