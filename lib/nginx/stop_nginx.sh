# shellcheck shell=bash

function stop_nginx() {
  if nginx_container_exists_any; then
    require_managed_nginx_container "stop-nginx" || return 1
    if container_running "$NGINX_CONTAINER_NAME"; then
      docker stop "$NGINX_CONTAINER_NAME"
      echo "[Info] Stopped Nginx container."
      log_msg "Stopped Nginx container."
    else
      echo "[Info] Nginx container already stopped."
    fi
  else
    echo "[Info] No Nginx container to stop."
  fi
}
