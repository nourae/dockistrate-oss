# shellcheck shell=bash

function show_nginx_docker_opts() {
  if [ -n "${NGINX_DOCKER_OPTS:-}" ]; then
    echo "$NGINX_DOCKER_OPTS"
  else
    echo "[None]"
  fi
}
