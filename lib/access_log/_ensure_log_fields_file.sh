# shellcheck shell=bash

function _ensure_log_fields_file() {
  _access_log_require_fields_file || return 1
  if declare -F validate_access_log_fields_state_for_render >/dev/null 2>&1; then
    validate_access_log_fields_state_for_render || return 1
  fi
  if ! csv_require_header "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER"; then
    return 1
  fi

  local row_count
  row_count="$(csv_data_row_count "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER")" || return 1
  if [ "$row_count" -gt 0 ]; then
    return 0
  fi

  csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$realip_remote_addr'
  csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$remote_addr'
  csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$host'
  csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '"$request"'
  csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$status'
  csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$body_bytes_sent'
  csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '"$http_referer"'
  csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '"$http_user_agent"'
}
