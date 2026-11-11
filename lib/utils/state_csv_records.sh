# shellcheck shell=bash

if ! declare -F csv_read_records >/dev/null 2>&1; then
  # shellcheck source=./csv_records.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/csv_records.sh"
fi

function _state_csv_record_noop() {
  return 0
}

# Produce an in-memory canonical view. Reordered shared input is never
# rewritten by a read; successful explicit mutations may write canonical order.
function state_csv_contents() {
  local file="$1" header="$2" _state_port_keys=$'\n'
  case "$header" in
  "$STATE_CUSTOM_HEADERS_HEADER" | "$STATE_PORT_TLS_PROTOCOLS_HEADER" | "$STATE_PORT_TLS_CIPHERS_HEADER")
    printf '%s\n' "$header" || return 1
    csv_read_records "$file" "$header" _state_csv_emit_record table
    ;;
  *) cat "$file" ;;
  esac
}

function _state_csv_emit_record() {
  shift 2
  case "$header" in
  "$STATE_PORT_TLS_PROTOCOLS_HEADER" | "$STATE_PORT_TLS_CIPHERS_HEADER")
    local port="" raw_port="$1"
    if port="$(normalize_port "$raw_port")"; then
      case "$_state_port_keys" in *$'\n'"$port"$'\n'*) echo "[Error] Duplicate TLS override for port $port" >&2; return 1 ;; esac
      _state_port_keys="${_state_port_keys}${port}"$'\n'
      shift
      csv_join_row "$port" "$@"
      return
    fi
    ;;
  esac
  csv_join_row "$@"
}

function state_csv_column_values() {
  local file="$1" header="$2" column="$3" records="" line="" line_no=0
  records="$(state_csv_contents "$file" "$header")" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1)); [ "$line_no" -gt 1 ] || continue
    csv_parse_line "$line" || return 1
    [ "$column" -lt "$CSV_FIELD_COUNT" ] || return 1
    printf '%s\n' "${CSV_FIELDS[column]}"
  done <<<"$records"
}

# Historical recovery must use the domain and aggregate codecs together. These
# assignments honor the caller's local variables so scoped recovery cannot
# change the normal process contract after it returns.
function state_security_rules_use_schema() {
  case "${1:-}" in
  1 | 2 | 3 | 4)
    STATE_SECURITY_RULES_HEADER="$STATE_SECURITY_RULES_LEGACY_HEADER"
    STATE_SECURITY_RULES_COLS=47
    ;;
  5)
    STATE_SECURITY_RULES_HEADER="${STATE_SECURITY_RULES_LEGACY_HEADER},action"
    STATE_SECURITY_RULES_COLS=48
    ;;
  *) return 1 ;;
  esac
}
