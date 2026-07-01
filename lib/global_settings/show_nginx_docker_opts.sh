# shellcheck shell=bash

function show_nginx_docker_opts() {
  if [ -n "${NGINX_DOCKER_OPTS:-}" ]; then
    operator_value_for_display docker_opts "$NGINX_DOCKER_OPTS"
    echo
  else
    echo "[None]"
  fi
}
