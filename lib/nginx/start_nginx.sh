# shellcheck shell=bash

function start_nginx() {
  local nginx_image_override=""
  local nginx_docker_opts_override=""
  local nginx_docker_opts_provided=false
  local started_txn=false explicit_runtime_rollback_started=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --nginx-image)
      if [ $# -lt 2 ]; then
        echo "[Error] --nginx-image requires an image reference" >&2
        return 1
      fi
      nginx_image_override="${2:-}"
      shift 2 || true
      ;;
    --docker-opts)
      if [ $# -lt 2 ]; then
        echo "[Error] --docker-opts requires an options string (use '' to clear)" >&2
        return 1
      fi
      nginx_docker_opts_override="${2-}"
      nginx_docker_opts_provided=true
      shift 2 || true
      ;;
    *)
      echo "[Usage] start-nginx [--nginx-image image[:tag]] [--docker-opts opts]" >&2
      return 1
      ;;
    esac
  done

  local old_nginx_image="$NGINX_IMAGE"
  local old_nginx_docker_opts="$NGINX_DOCKER_OPTS"
  local new_nginx_image="$old_nginx_image"
  local new_nginx_docker_opts="$old_nginx_docker_opts"
  local config_updated=false
  local image_changed=false
  local docker_opts_changed=false

  if [ -n "$nginx_image_override" ]; then
    if ! is_valid_image_ref "$nginx_image_override"; then
      echo "[Error] Invalid image reference: ${nginx_image_override}" >&2
      return 1
    fi
    local normalized_image
    normalized_image="$(normalize_nginx_image "$nginx_image_override")"
    if [ "$normalized_image" != "$nginx_image_override" ]; then
      echo "[Info] No tag supplied; defaulting to $normalized_image."
    fi
    new_nginx_image="$normalized_image"
  fi

  if [ "$nginx_docker_opts_provided" = true ]; then
    local normalized_nginx_docker_opts=""
    if [ -n "$nginx_docker_opts_override" ]; then
      if ! normalized_nginx_docker_opts="$(normalize_docker_opts_for_storage "$nginx_docker_opts_override" "nginx docker options for proxy container" "nginx")"; then
        return 1
      fi
    fi
    new_nginx_docker_opts="$normalized_nginx_docker_opts"
  fi

  if [ "$new_nginx_image" != "$old_nginx_image" ]; then
    image_changed=true
    config_updated=true
  fi
  if [ "$new_nginx_docker_opts" != "$old_nginx_docker_opts" ]; then
    docker_opts_changed=true
    config_updated=true
  fi

  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && ! ensure_no_nginx_container_conflict "start-nginx"; then
    return 1
  fi

  if ! _config_begin_transaction_if_needed started_txn "start_nginx"; then
    return 1
  fi

  if [ "$config_updated" = true ]; then
    NGINX_IMAGE="$new_nginx_image"
    NGINX_DOCKER_OPTS="$new_nginx_docker_opts"
  fi

  if [ "$config_updated" = true ]; then
    save_config
  fi

  if [ -n "$nginx_image_override" ]; then
    echo "[Info] Using Nginx image $NGINX_IMAGE (saved to $GLOBAL_SETTINGS_FILE)."
  fi

  if [ "$nginx_docker_opts_provided" = true ]; then
    if [ -n "$NGINX_DOCKER_OPTS" ]; then
      echo "[Info] Saved Nginx docker options: $(operator_value_for_display docker_opts "$NGINX_DOCKER_OPTS")"
    else
      echo "[Info] Cleared saved Nginx docker options."
    fi
  fi

  local had_container=false
  if nginx_container_is_managed; then
    had_container=true
  fi

  # Generate default config and clean up old files
  create_nginx_config
  # Rebuild all backend configs (removing duplicates) and reload container
  update_nginx_config

  if [ "$had_container" = true ] && { [ "$image_changed" = true ] || [ "$docker_opts_changed" = true ]; }; then
    _nginx_prepare_runtime_rollback "$old_nginx_image"
    explicit_runtime_rollback_started=true
    recreate_nginx_container "$NGINX_IMAGE"
  fi

  if container_running "$NGINX_CONTAINER_NAME"; then
    _config_end_transaction_if_started "$started_txn"
    if [ "$explicit_runtime_rollback_started" = true ]; then
      _nginx_release_runtime_rollback
    fi
    echo "[Info] Nginx proxy running."
    return 0
  else
    NGINX_IMAGE="$old_nginx_image"
    NGINX_DOCKER_OPTS="$old_nginx_docker_opts"
    echo "[Error] Nginx container failed to start. Check logs in $ERROR_LOG_DIR." >&2
    _rollback_handler
  fi
}

# Added get_stats function to capture container statistics
