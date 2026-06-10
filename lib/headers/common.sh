# shellcheck shell=bash

function _escape_header_value() {
  local val="${1:-}"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  printf '%s' "$val"
}

function _is_valid_header_type() {
  case "${1:-}" in
  request | response) return 0 ;;
  *) return 1 ;;
  esac
}

function _persisted_header_error() {
  local file="${1:-}" line_no="${2:-0}" reason="${3:-invalid header row}"
  echo "[Error] Invalid persisted header row in ${file} at line ${line_no}: ${reason}" >&2
  return 1
}

function _validate_persisted_header_row() {
  local file="${1:-}" line_no="${2:-0}" domain="${3:-}" type="${4:-}" name="${5:-}" value="${6:-}" require_domain="${7:-no}"

  if [ "$require_domain" = "yes" ] && [ -z "$domain" ]; then
    _persisted_header_error "$file" "$line_no" "domain cannot be empty"
    return 1
  fi
  if [ -n "$domain" ] && ! is_valid_domain "$domain"; then
    _persisted_header_error "$file" "$line_no" "domain '${domain}' is invalid"
    return 1
  fi
  if ! _is_valid_header_type "$type"; then
    _persisted_header_error "$file" "$line_no" "type '${type}' must be request or response"
    return 1
  fi
  if ! is_valid_header_name "$name"; then
    _persisted_header_error "$file" "$line_no" "header name '${name}' is invalid"
    return 1
  fi
  if ! is_valid_header_value "$value"; then
    _persisted_header_error "$file" "$line_no" "header value for '${name}' is invalid"
    return 1
  fi
  return 0
}

function _backend_ip_header_override_exists() {
  local domain="${1:-}" file="${2:-}" csv_header="${3:-}" expected_cols="${4:-0}"
  [ -n "$domain" ] || return 1
  state_csv_has_row_by_keys "$file" "$csv_header" "$expected_cols" 1 "$domain" 2>/dev/null
}

function _backend_ip_header_override_value() {
  local domain="${1:-}" file="${2:-}" csv_header="${3:-}"
  [ -n "$domain" ] || return 0
  state_csv_get_two_col_value "$file" "$csv_header" "$domain" "" 2>/dev/null || true
}

function _resolve_backend_ip_header() {
  local domain="${1:-}" default_header="${2:-}" file="${3:-}" csv_header="${4:-}" expected_cols="${5:-0}"
  [ -n "$domain" ] && domain="$(normalize_domain "$domain")"

  local resolved_header="$default_header"
  local has_explicit_override="no"

  if [ -n "$domain" ] && _backend_ip_header_override_exists "$domain" "$file" "$csv_header" "$expected_cols"; then
    resolved_header="$(_backend_ip_header_override_value "$domain" "$file" "$csv_header")"
    [ "$resolved_header" = "off" ] && resolved_header=""
    has_explicit_override="yes"
  fi

  if [ "$has_explicit_override" = "no" ]; then
    local target_domain should_inherit="yes"
    target_domain="$(backend_for_dedicated_host "$domain")"
    if [ -n "$target_domain" ]; then
      if command -v should_inherit_headers >/dev/null 2>&1; then
        should_inherit_headers "$domain" && should_inherit="yes" || should_inherit="no"
      fi
      if [ "$should_inherit" = "yes" ]; then
        resolved_header="$(_resolve_backend_ip_header "$target_domain" "$default_header" "$file" "$csv_header" "$expected_cols")"
      fi
    fi
  fi

  echo "$resolved_header"
}

function get_backend_client_ip_header() {
  local domain="${1:-}"
  _resolve_backend_ip_header "$domain" "$CLIENT_IP_HEADER" "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$STATE_BACKEND_CLIENT_IP_HEADERS_COLS"
}

function get_backend_header_value() {
  local domain="${1:-}" name="${2:-}" type="${3:-response}" val=""
  local line="" line_no=0
  domain="$(normalize_domain "$domain")"
  if [ -f "$BACKEND_HEADERS_FILE" ] && [ -n "$domain" ]; then
    if ! csv_require_header "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER"; then
      echo ""
      return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      csv_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_HEADERS_COLS" ] || continue
      if [ "${CSV_FIELDS[0]}" = "$domain" ] && [ "${CSV_FIELDS[1]}" = "$type" ] && [ "${CSV_FIELDS[2]}" = "$name" ]; then
        val="${CSV_FIELDS[3]}"
        break
      fi
    done <"$BACKEND_HEADERS_FILE"
  fi
  echo "$val"
}

function get_backend_proxy_ip_header() {
  local domain="${1:-}"
  _resolve_backend_ip_header "$domain" "$PROXY_IP_HEADER" "$BACKEND_PROXY_IP_HEADER_FILE" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" "$STATE_BACKEND_PROXY_IP_HEADERS_COLS"
}

function get_global_header_value() {
  local name="${1:-}" type="${2:-response}" val=""
  local line="" line_no=0
  if [ -f "$CUSTOM_HEADERS_FILE" ]; then
    if ! csv_require_header "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER"; then
      echo ""
      return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      csv_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_CUSTOM_HEADERS_COLS" ] || continue
      if [ "${CSV_FIELDS[0]}" = "$type" ] && [ "${CSV_FIELDS[1]}" = "$name" ]; then
        val="${CSV_FIELDS[2]}"
        break
      fi
    done <"$CUSTOM_HEADERS_FILE"
  fi
  echo "$val"
}
