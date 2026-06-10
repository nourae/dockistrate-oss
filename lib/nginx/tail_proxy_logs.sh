# shellcheck shell=bash

function tail_proxy_logs() {
  local lines="${1:-200}"
  require_managed_nginx_container "tail-proxy-logs" || return 1
  docker logs -f --tail "$lines" "$NGINX_CONTAINER_NAME"
}
