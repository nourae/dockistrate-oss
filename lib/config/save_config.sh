# shellcheck shell=bash

function _save_config_write_rows() {
  echo "$STATE_GLOBAL_SETTINGS_HEADER" || return 1
  csv_join_row "ENABLE_AUTO_BACKUPS" "$ENABLE_AUTO_BACKUPS" || return 1
  csv_join_row "BACKUP_RETENTION" "$BACKUP_RETENTION" || return 1
  csv_join_row "ENABLE_BACKUP_COMPRESSION" "$ENABLE_BACKUP_COMPRESSION" || return 1
  csv_join_row "HTTP_VERSION" "$HTTP_VERSION" || return 1
  csv_join_row "CLIENT_IP_HEADER" "$CLIENT_IP_HEADER" || return 1
  csv_join_row "PROXY_IP_HEADER" "$PROXY_IP_HEADER" || return 1
  csv_join_row "TLS_PROTOCOLS" "$TLS_PROTOCOLS" || return 1
  csv_join_row "TLS_CIPHERS" "$TLS_CIPHERS" || return 1
  csv_join_row "SECURITY_RULE_STATUS" "$SECURITY_RULE_STATUS" || return 1
  csv_join_row "ACL_STATUS" "$ACL_STATUS" || return 1
  csv_join_row "ACL_POLICY" "$ACL_POLICY" || return 1
  csv_join_row "TRUSTED_PROXY_RANGES" "$TRUSTED_PROXY_RANGES" || return 1
  csv_join_row "REAL_IP_RECURSIVE" "$REAL_IP_RECURSIVE" || return 1
  csv_join_row "NGINX_DIRECTIVE_STRICT" "$NGINX_DIRECTIVE_STRICT" || return 1
  csv_join_row "NGINX_DOCKER_OPTS" "$NGINX_DOCKER_OPTS" || return 1
  csv_join_row "VISIBILITY_POLICY" "${VISIBILITY_POLICY:-${DEFAULT_VISIBILITY_POLICY:-full}}" || return 1
  csv_join_row "NGINX_IMAGE" "$NGINX_IMAGE" || return 1
  csv_join_row "CERTBOT_IMAGE" "$CERTBOT_IMAGE" || return 1
  csv_join_row "NGINX_PULL_MODE" "$NGINX_PULL_MODE" || return 1
  csv_join_row "CERTBOT_PULL_MODE" "$CERTBOT_PULL_MODE" || return 1
}

function _save_config_atomic_write() {
  local tmp_file=""
  local settings_dir=""

  settings_dir="$(dirname "$GLOBAL_SETTINGS_FILE")"
  if declare -F runtime_state_path_guard >/dev/null 2>&1; then
    runtime_state_path_guard "$settings_dir" "global settings directory" || return 1
    runtime_state_path_guard "$GLOBAL_SETTINGS_FILE" "global settings file" || return 1
  fi
  mkdir -p "$settings_dir" || return 1
  if declare -F runtime_state_path_guard >/dev/null 2>&1; then
    runtime_state_path_guard "$settings_dir" "global settings directory" || return 1
    runtime_state_path_guard "$GLOBAL_SETTINGS_FILE" "global settings file" || return 1
  fi
  if declare -F make_temp_for_file >/dev/null 2>&1; then
    make_temp_for_file tmp_file "$GLOBAL_SETTINGS_FILE" || return 1
  else
    tmp_file="${GLOBAL_SETTINGS_FILE}.tmp.$$"
  fi

  if ! _save_config_write_rows >"$tmp_file"; then
    [ -n "$tmp_file" ] && rm -f "$tmp_file"
    return 1
  fi

  if declare -F finalize_temp_file >/dev/null 2>&1; then
    if ! finalize_temp_file "$GLOBAL_SETTINGS_FILE" "$tmp_file"; then
      [ -n "$tmp_file" ] && rm -f "$tmp_file"
      return 1
    fi
  else
    if declare -F runtime_state_path_guard >/dev/null 2>&1; then
      runtime_state_path_guard "$GLOBAL_SETTINGS_FILE" "global settings file" || {
        [ -n "$tmp_file" ] && rm -f "$tmp_file"
        return 1
      }
    fi
    if ! mv -f "$tmp_file" "$GLOBAL_SETTINGS_FILE"; then
      [ -n "$tmp_file" ] && rm -f "$tmp_file"
      return 1
    fi
  fi
}

function save_config() {
  local started_txn=false

  if declare -F _config_begin_return_transaction_if_needed >/dev/null 2>&1; then
    _config_begin_return_transaction_if_needed started_txn "save_config" "$GLOBAL_SETTINGS_FILE" || return 1
  fi

  _save_config_atomic_write || {
    transaction_return_failure
    return 1
  }

  if [ "$started_txn" = true ] && declare -F _config_end_transaction_if_started >/dev/null 2>&1; then
    _config_end_transaction_if_started "$started_txn" || return 1
  fi
}
