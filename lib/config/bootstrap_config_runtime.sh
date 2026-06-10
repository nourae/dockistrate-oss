# shellcheck shell=bash

function _config_migrate_loaded_settings() {
  local updated=false
  local saw_nginx_image="${1:-false}"
  local saw_certbot_image="${2:-false}"
  local saw_nginx_pull_mode="${3:-false}"
  local saw_certbot_pull_mode="${4:-false}"
  local saw_nginx_directive_strict="${5:-false}"
  local saw_nginx_docker_opts="${6:-false}"

  local normalized_nginx="${NGINX_IMAGE:-}"
  local normalized_certbot="${CERTBOT_IMAGE:-}"

  normalized_nginx="$(normalize_image_with_latest "${NGINX_IMAGE:-}")" || return 1
  normalized_certbot="$(normalize_image_with_latest "${CERTBOT_IMAGE:-}")" || return 1

  if [ "${NGINX_IMAGE:-}" != "$normalized_nginx" ]; then
    NGINX_IMAGE="$normalized_nginx"
    updated=true
  fi

  if [ "${CERTBOT_IMAGE:-}" != "$normalized_certbot" ]; then
    CERTBOT_IMAGE="$normalized_certbot"
    updated=true
  fi

  if ! is_on_off "$NGINX_DIRECTIVE_STRICT"; then
    NGINX_DIRECTIVE_STRICT="$DEFAULT_NGINX_DIRECTIVE_STRICT"
    updated=true
  fi

  if [ "$saw_nginx_image" = false ] ||
    [ "$saw_certbot_image" = false ] ||
    [ "$saw_nginx_pull_mode" = false ] ||
    [ "$saw_certbot_pull_mode" = false ] ||
    [ "$saw_nginx_directive_strict" = false ] ||
    [ "$saw_nginx_docker_opts" = false ]; then
    updated=true
  fi

  if [ "$updated" = true ]; then
    if ! declare -F _config_write_lock_is_active >/dev/null 2>&1 ||
      ! _config_write_lock_is_active; then
      echo "[Error] Refusing to migrate global settings without the config write lock." >&2
      return 1
    fi
    _save_config_atomic_write || return 1
  fi
}

function _bootstrap_config_runtime_locked() {
  # Runtime prep can run on read-only commands like status/status-all.
  # Keep opportunistic repairs atomic, but do not emit transactional backups
  # here so backup history only reflects operator-driven config changes.
  if declare -F runtime_state_paths_guard >/dev/null 2>&1; then
    runtime_state_paths_guard "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$CAPTURE_DIR" "$ACME_WEBROOT_DIR" "$CERTS_DIR" || {
      transaction_return_failure
      return 1
    }
  fi
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$CAPTURE_DIR" "$ACME_WEBROOT_DIR" "$CERTS_DIR" || {
    transaction_return_failure
    return 1
  }
  if declare -F runtime_state_paths_guard >/dev/null 2>&1; then
    runtime_state_paths_guard "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$CAPTURE_DIR" "$ACME_WEBROOT_DIR" "$CERTS_DIR" || {
      transaction_return_failure
      return 1
    }
  fi

  if declare -F state_schema_bootstrap >/dev/null 2>&1; then
    state_schema_bootstrap || {
      transaction_return_failure
      return 1
    }
  fi

  if [ ! -s "$GLOBAL_SETTINGS_FILE" ]; then
    config_reset_defaults
    _save_config_atomic_write || {
      transaction_return_failure
      return 1
    }
  fi

  load_config || {
    transaction_return_failure
    return 1
  }
  _config_migrate_loaded_settings \
    "$LOAD_CONFIG_SAW_NGINX_IMAGE" \
    "$LOAD_CONFIG_SAW_CERTBOT_IMAGE" \
    "$LOAD_CONFIG_SAW_NGINX_PULL_MODE" \
    "$LOAD_CONFIG_SAW_CERTBOT_PULL_MODE" \
    "$LOAD_CONFIG_SAW_NGINX_DIRECTIVE_STRICT" \
    "$LOAD_CONFIG_SAW_NGINX_DOCKER_OPTS" || {
    transaction_return_failure
    return 1
  }

  if declare -F state_csv_ensure_all_state_files >/dev/null 2>&1; then
    state_csv_ensure_all_state_files || {
      transaction_return_failure
      return 1
    }
  fi

  if declare -F _ensure_log_fields_file >/dev/null 2>&1; then
    _ensure_log_fields_file || {
      transaction_return_failure
      return 1
    }
  fi

  if declare -F ensure_runtime_state_permissions >/dev/null 2>&1; then
    ensure_runtime_state_permissions || {
      transaction_return_failure
      return 1
    }
  fi
}

function bootstrap_config_runtime() {
  if declare -F runtime_state_paths_guard >/dev/null 2>&1; then
    runtime_state_paths_guard "$TMP_DIR" "$BACKUP_DIR" || return 1
  fi
  mkdir -p "$TMP_DIR" "$BACKUP_DIR" || return 1
  if declare -F runtime_state_paths_guard >/dev/null 2>&1; then
    runtime_state_paths_guard "$TMP_DIR" "$BACKUP_DIR" || return 1
  fi

  if ! declare -F _config_begin_runtime_prep_lock_if_needed >/dev/null 2>&1 ||
    ! declare -F _config_end_runtime_prep_lock_if_started >/dev/null 2>&1; then
    echo "[Error] Runtime preparation requires config lock helpers." >&2
    return 1
  fi

  local started_lock=false status=0
  _config_begin_runtime_prep_lock_if_needed started_lock || return 1

  _bootstrap_config_runtime_locked || status=$?

  if ! _config_end_runtime_prep_lock_if_started "$started_lock"; then
    [ "$status" -eq 0 ] && status=1
  fi

  return "$status"
}
