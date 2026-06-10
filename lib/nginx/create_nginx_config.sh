# shellcheck shell=bash

function create_nginx_config() {
  local nginx_main_config="${NGINX_CONFIG_DIR}/nginx.conf"
  local access_log_fields_dir=""

  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$NGINX_CONFIG_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$ACCESS_LOG_FIELDS_FILE" || return 1
  fi
  if [ -f "$NGINX_CONFIG_DIR" ]; then
    echo "[Warn] Expected directory but found file at ${NGINX_CONFIG_DIR}; recreating." >&2
    rm -f "$NGINX_CONFIG_DIR"
  fi
  mkdir -p "$NGINX_CONFIG_DIR"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$NGINX_CONFIG_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$ACCESS_LOG_FIELDS_FILE" || return 1
  fi

  if [ -f "$NGINX_HTTP_CONF_DIR" ]; then
    echo "[Warn] Expected directory but found file at ${NGINX_HTTP_CONF_DIR}; recreating." >&2
    rm -f "$NGINX_HTTP_CONF_DIR"
  fi
  if [ -f "$NGINX_STREAM_CONF_DIR" ]; then
    echo "[Warn] Expected directory but found file at ${NGINX_STREAM_CONF_DIR}; recreating." >&2
    rm -f "$NGINX_STREAM_CONF_DIR"
  fi
  mkdir -p "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$NGINX_CONFIG_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$ACCESS_LOG_FIELDS_FILE" || return 1
  fi

  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$nginx_main_config" "nginx main config file" || return 1
  fi
  if [ -d "$nginx_main_config" ]; then
    echo "[Warn] Expected file but found directory at ${nginx_main_config}; regenerating." >&2
    rm -rf "$nginx_main_config"
  fi

  fix_default_config
  cleanup_leftovers
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$NGINX_STREAM_CONF_DIR" "nginx stream config directory" || return 1
  fi
  mkdir -p "${NGINX_STREAM_CONF_DIR}"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared \
      "${NGINX_HTTP_CONF_DIR}/security_rules.inc" \
      "$NGINX_DIRECTIVES_GLOBAL_INCLUDE_FILE" \
      "$NGINX_DIRECTIVES_STREAM_GLOBAL_INCLUDE_FILE" || return 1
  fi
  # Ensure optional include files exist so Nginx doesn't fail on missing files
  touch "${NGINX_HTTP_CONF_DIR}/security_rules.inc"
  touch "${NGINX_DIRECTIVES_GLOBAL_INCLUDE_FILE}"
  touch "${NGINX_DIRECTIVES_STREAM_GLOBAL_INCLUDE_FILE}"
  access_log_fields_dir="$(dirname "$ACCESS_LOG_FIELDS_FILE")"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$access_log_fields_dir" "access log fields directory" || return 1
    runtime_state_path_guard_if_declared "$ACCESS_LOG_FIELDS_FILE" "access log fields file" || return 1
  fi
  mkdir -p "$access_log_fields_dir"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$access_log_fields_dir" "access log fields directory" || return 1
    runtime_state_path_guard_if_declared "$ACCESS_LOG_FIELDS_FILE" "access log fields file" || return 1
  fi
  if declare -F _ensure_log_fields_file >/dev/null 2>&1; then
    _ensure_log_fields_file || return 1
  else
    if declare -F validate_access_log_fields_state_for_render >/dev/null 2>&1; then
      validate_access_log_fields_state_for_render || return 1
    fi
    csv_require_header "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" || return 1
    if [ "$(csv_data_row_count "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER")" -eq 0 ]; then
      csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$realip_remote_addr'
      csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$remote_addr'
      csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$host'
      csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '"$request"'
      csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$status'
      csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '$body_bytes_sent'
      csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '"$http_referer"'
      csv_append_row "$ACCESS_LOG_FIELDS_FILE" "$STATE_ACCESS_LOG_FIELDS_HEADER" '"$http_user_agent"'
    fi
  fi
  if declare -F validate_access_log_fields_state_for_render >/dev/null 2>&1; then
    validate_access_log_fields_state_for_render || return 1
  fi

  local -a log_fields_parts=()
  local log_fields="" line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_ACCESS_LOG_FIELDS_COLS" ] || continue
    [ -n "${CSV_FIELDS[0]}" ] || continue
    if declare -F _access_log_validate_field_or_error >/dev/null 2>&1; then
      _access_log_validate_field_or_error "${CSV_FIELDS[0]}" "$line_no" "$ACCESS_LOG_FIELDS_FILE" || return 1
    elif declare -F is_valid_log_field >/dev/null 2>&1 && ! is_valid_log_field "${CSV_FIELDS[0]}"; then
      echo "[Error] Invalid access log field in ${ACCESS_LOG_FIELDS_FILE} at line ${line_no}: field must be non-empty and cannot contain single quotes, semicolons, or control characters" >&2
      return 1
    fi
    log_fields_parts+=("${CSV_FIELDS[0]}")
  done <"$ACCESS_LOG_FIELDS_FILE"
  if [ "${#log_fields_parts[@]}" -gt 0 ]; then
    log_fields="$(IFS=' '; echo "${log_fields_parts[*]}")"
  else
    log_fields='$realip_remote_addr $remote_addr $host "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"'
  fi
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$nginx_main_config" "nginx main config file" || return 1
  fi
  cat >"$nginx_main_config" <<EOF
worker_processes  1;
env SSLKEYLOGFILE;

events {
    worker_connections  1024;
}

http {
    log_format dockistrate '$log_fields';
    access_log /var/log/nginx/access.log dockistrate;
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    sendfile        on;
    keepalive_timeout 65;

    include ${NGINX_CONTAINER_DIRECTIVES_GLOBAL_INCLUDE_FILE};
    include ${NGINX_CONTAINER_HTTP_CONF_DIR}/*.conf;
}

stream {
    include ${NGINX_CONTAINER_DIRECTIVES_STREAM_GLOBAL_INCLUDE_FILE};
    include ${NGINX_CONTAINER_STREAM_CONF_DIR}/*.conf;
}
EOF
}
