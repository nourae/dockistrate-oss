# shellcheck shell=bash

function set_nginx_image() {
  local image="${1:-}" pull_mode="${2:-}"
  local old_nginx_image="${NGINX_IMAGE:-}"
  local old_nginx_pull_mode="${NGINX_PULL_MODE:-}"
  local started_txn=false
  if [ -z "$image" ]; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-nginx-image <image[:tag]> [pull_mode]" >&2
    return 1
  fi
  if [ -n "$pull_mode" ] && [[ ! "$pull_mode" =~ ^(always|if-missing|never)$ ]]; then
    echo "${GLOBAL_SETTINGS_ERROR_PREFIX} Invalid pull mode: $pull_mode (expected always|if-missing|never)" >&2
    return 1
  fi
  if ! is_valid_image_ref "$image"; then
    echo "${GLOBAL_SETTINGS_ERROR_PREFIX} Invalid image reference: $image" >&2
    return 1
  fi
  local normalized_image
  normalized_image="$(normalize_nginx_image "$image")" || return 1
  if [ "$normalized_image" != "$image" ]; then
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} No tag supplied; defaulting to $normalized_image."
  fi
  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && ! ensure_no_nginx_container_conflict "set-nginx-image"; then
    return 1
  fi
  _config_begin_return_transaction_if_needed started_txn "set_nginx_image" || return 1
  NGINX_IMAGE="$normalized_image"
  [ -n "$pull_mode" ] && NGINX_PULL_MODE="$pull_mode"
  save_config || { transaction_return_failure; return 1; }
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} NGINX_IMAGE set to $NGINX_IMAGE and saved in $GLOBAL_SETTINGS_FILE."
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} NGINX pull mode: ${NGINX_PULL_MODE}"
  if image_uses_latest_tag "$NGINX_IMAGE"; then
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} Latest-tagged Nginx image will be auto-pulled according to pull mode (${NGINX_PULL_MODE})."
  else
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} Pinned Nginx image will skip auto-pull; Docker will use the specified reference."
  fi
  if [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} SKIP_DOCKER_CHECKS=true: configuration updated without recreating Nginx."
    _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
    return 0
  fi
  create_nginx_config || { transaction_return_failure; return 1; }
  update_nginx_config || { transaction_return_failure; return 1; }
  _nginx_prepare_runtime_rollback "$old_nginx_image" || { transaction_return_failure; return 1; }
  recreate_nginx_container "$NGINX_IMAGE" || { transaction_return_failure; return 1; }
  if ! nginx_container_is_managed || ! container_running "$NGINX_CONTAINER_NAME"; then
    NGINX_IMAGE="$old_nginx_image"
    NGINX_PULL_MODE="$old_nginx_pull_mode"
    _rollback_handler
  fi
  _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
  _nginx_release_runtime_rollback || { transaction_return_failure; return 1; }
}
