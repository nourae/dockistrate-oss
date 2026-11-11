# shellcheck shell=bash

function remove_nginx() {
  if nginx_container_exists_any; then
    require_managed_nginx_container "remove-nginx" || return 1
    if declare -F domain_config_runtime_enabled >/dev/null 2>&1 && domain_config_runtime_enabled; then
      _domain_runtime_stage_proxy_delete || return 1
      echo "[Info] Removing Nginx container after configuration commit."
      log_msg "Queued Nginx container removal."
      return 0
    fi
    remove_container_and_anonymous_volumes "$NGINX_CONTAINER_NAME"
    echo "[Info] Removed Nginx container."
    log_msg "Removed Nginx container."
  else
    echo "[Info] No Nginx container to remove."
  fi
}
