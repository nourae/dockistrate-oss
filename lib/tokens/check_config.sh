# shellcheck shell=bash

function check_config() {
  if require_managed_nginx_container "check-config"; then
    docker exec "$NGINX_CONTAINER_NAME" nginx -t -c "$NGINX_CONTAINER_MAIN_CONF"
  else
    return 1
  fi
}
