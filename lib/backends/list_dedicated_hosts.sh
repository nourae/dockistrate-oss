# shellcheck shell=bash
function list_dedicated_hosts() {
  local domain_filter="${1:-}"
  local aliases_file
  aliases_file="$(backend_aliases_file)"
  [ -f "$aliases_file" ] || {
    echo "[Info] No dedicated hosts configured."
    return
  }

  if [ -n "$domain_filter" ]; then
    domain_filter="$(primary_domain_for "$domain_filter")"
  fi

  local has_entries="false"
  printf "%-25s | %s\n" "Dedicated Host" "Backend"
  echo "---------------------------------------------"
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_ALIASES_COLS" ] || continue
    local type hostname target
    type="${CSV_FIELDS[0]}"
    hostname="${CSV_FIELDS[1]}"
    target="${CSV_FIELDS[2]}"
    [ "$type" = "dedicated" ] || continue
    if [ -n "$domain_filter" ] && [ "$target" != "$domain_filter" ]; then
      continue
    fi
    has_entries="true"
    printf "%-25s | %s\n" "$hostname" "$target"
  done <"$aliases_file"

  if [ "$has_entries" = "false" ]; then
    echo "[Info] No dedicated hosts configured${domain_filter:+ for ${domain_filter}}."
  fi
}
