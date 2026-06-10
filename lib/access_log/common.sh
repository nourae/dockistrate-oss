# shellcheck shell=bash
#
# access_log.sh - Manage access log fields

function _access_log_require_fields_file() {
  if [ -n "${ACCESS_LOG_FIELDS_FILE:-}" ]; then
    return 0
  fi
  if [ -z "${CONFIG_DIR:-}" ]; then
    echo "[Error] CONFIG_DIR is not set. Load config before using access log helpers." >&2
    return 1
  fi

  ACCESS_LOG_FIELDS_FILE="${CONFIG_DIR}/access_log_fields.csv"
}

# Validate a log field value to prevent nginx config injection.
# Valid log fields are either nginx variables (e.g. $remote_addr, "$request")
# or simple literals that don't contain dangerous characters that could break
# out of the log_format directive.
function is_valid_log_field() {
  local field="${1:-}"
  [ -z "$field" ] && return 1

  # Reject fields containing single quotes (would break nginx log_format syntax)
  # or semicolons (could inject new directives)
  if [[ "$field" == *"'"* ]] || [[ "$field" == *";"* ]]; then
    return 1
  fi

  # Reject control characters and null bytes
  if [[ "$field" =~ [[:cntrl:]] ]]; then
    return 1
  fi

  return 0
}

function _access_log_validate_field_or_error() {
  local field="${1:-}" line_no="${2:-}" context="${3:-access log fields}"
  if is_valid_log_field "$field"; then
    return 0
  fi

  if [ -n "$line_no" ]; then
    echo "[Error] Invalid access log field in ${context} at line ${line_no}: field must be non-empty and cannot contain single quotes, semicolons, or control characters" >&2
  else
    echo "[Error] Invalid access log field in ${context}: field must be non-empty and cannot contain single quotes, semicolons, or control characters" >&2
  fi
  return 1
}

function validate_access_log_fields_state_for_render() {
  _access_log_require_fields_file || return 1
  if [ ! -f "$ACCESS_LOG_FIELDS_FILE" ]; then
    if [ -e "$ACCESS_LOG_FIELDS_FILE" ] || [ -L "$ACCESS_LOG_FIELDS_FILE" ]; then
      echo "[Error] Access log fields state is not a regular file: ${ACCESS_LOG_FIELDS_FILE}" >&2
      return 1
    fi
    return 0
  fi
  csv_require_header "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" || return 1

  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid access log field row in ${ACCESS_LOG_FIELDS_FILE} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_ACCESS_LOG_FIELDS_COLS" ]; then
      echo "[Error] Invalid access log field column count in ${ACCESS_LOG_FIELDS_FILE} at line ${line_no}: expected ${STATE_ACCESS_LOG_FIELDS_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    _access_log_validate_field_or_error "${CSV_FIELDS[0]}" "$line_no" "$ACCESS_LOG_FIELDS_FILE" || return 1
  done <"$ACCESS_LOG_FIELDS_FILE"
  return 0
}

function _access_log_load_fields() {
  _access_log_require_fields_file || return 1
  ACCESS_LOG_FIELDS=()
  _ensure_log_fields_file || return 1

  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid access log field row at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_ACCESS_LOG_FIELDS_COLS" ]; then
      echo "[Error] Invalid access log field column count at line ${line_no}: expected ${STATE_ACCESS_LOG_FIELDS_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    _access_log_validate_field_or_error "${CSV_FIELDS[0]}" "$line_no" "$ACCESS_LOG_FIELDS_FILE" || return 1
    ACCESS_LOG_FIELDS+=("${CSV_FIELDS[0]}")
  done <"$ACCESS_LOG_FIELDS_FILE"
}

function _access_log_write_fields() {
  local -a fields=("$@")
  local tmp_file=""

  _access_log_require_fields_file || return 1
  csv_require_header "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" || return 1
  make_temp_for_file tmp_file "$ACCESS_LOG_FIELDS_FILE" || return 1
  printf '%s\n' "$STATE_ACCESS_LOG_FIELDS_HEADER" >"$tmp_file"

  local field
  for field in "${fields[@]}"; do
    _access_log_validate_field_or_error "$field" "" "$ACCESS_LOG_FIELDS_FILE" || {
      rm -f "$tmp_file"
      return 1
    }
    csv_join_row "$field" >>"$tmp_file"
  done

  finalize_temp_file "$ACCESS_LOG_FIELDS_FILE" "$tmp_file"
}
