# shellcheck shell=bash

function list_backend_headers() {
  local domain="${1:-}"
  domain="$(normalize_domain "$domain")"
  if [ ! -e "$BACKEND_HEADERS_FILE" ] && [ ! -L "$BACKEND_HEADERS_FILE" ]; then
    echo "[None]"
    return
  fi

  local records=""
  records="$(_header_records "$BACKEND_HEADERS_FILE" backend)" || return 1

  local line="" line_no=0 printed=false
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_HEADERS_COLS" ] || return 1
    if [ -n "$domain" ] && [ "${CSV_FIELDS[0]}" != "$domain" ]; then
      continue
    fi
    printed=true
    echo "${CSV_FIELDS[0]} ${CSV_FIELDS[1]} ${CSV_FIELDS[2]} $(operator_value_for_display header_value "${CSV_FIELDS[3]}")"
  done <<<"$records"

  if [ "$printed" = false ]; then
    echo "[None]"
  fi
}

# Fetch current global header value for convenience defaults
