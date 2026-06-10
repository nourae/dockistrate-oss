# shellcheck shell=bash

function remove_nginx() {
  if nginx_container_exists_any; then
    require_managed_nginx_container "remove-nginx" || return 1
    remove_container_and_anonymous_volumes "$NGINX_CONTAINER_NAME"
    echo "[Info] Removed Nginx container."
    log_msg "Removed Nginx container."
  else
    echo "[Info] No Nginx container to remove."
  fi
}
