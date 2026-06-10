# shellcheck shell=bash

function set_nginx_docker_opts() {
  local old_nginx_docker_opts="${NGINX_DOCKER_OPTS:-}"
  local started_txn=false
  if [ "$#" -lt 1 ]; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-nginx-docker-opts <opts>" >&2
    return 1
  fi

  local raw_opts="$*"
  local normalized_opts=""
  if [ -n "$raw_opts" ]; then
    normalized_opts="$(normalize_docker_opts_for_storage "$raw_opts" "nginx docker options" "nginx")" || return 1
  fi

  if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ] && ! ensure_no_nginx_container_conflict "set-nginx-docker-opts"; then
    return 1
  fi

  _config_begin_return_transaction_if_needed started_txn "set_nginx_docker_opts" || return 1
  NGINX_DOCKER_OPTS="$normalized_opts"
  save_config || { transaction_return_failure; return 1; }

  if [ -n "$NGINX_DOCKER_OPTS" ]; then
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} NGINX_DOCKER_OPTS set and saved in $GLOBAL_SETTINGS_FILE."
  else
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} NGINX_DOCKER_OPTS cleared in $GLOBAL_SETTINGS_FILE."
  fi

  if [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} SKIP_DOCKER_CHECKS=true: configuration updated without recreating Nginx."
    _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
    return 0
  fi

  create_nginx_config || { transaction_return_failure; return 1; }
  update_nginx_config || { transaction_return_failure; return 1; }
  _nginx_prepare_runtime_rollback "$NGINX_IMAGE" || { transaction_return_failure; return 1; }
  recreate_nginx_container "$NGINX_IMAGE" || { transaction_return_failure; return 1; }
  if ! nginx_container_is_managed || ! container_running "$NGINX_CONTAINER_NAME"; then
    NGINX_DOCKER_OPTS="$old_nginx_docker_opts"
    _rollback_handler
  fi
  _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
  _nginx_release_runtime_rollback || { transaction_return_failure; return 1; }
}
