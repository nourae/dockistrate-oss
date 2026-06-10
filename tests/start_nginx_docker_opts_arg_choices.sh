#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/arg_choices_network_docker.sh
source "$ROOT_DIR/lib/cli/arg_choices_network_docker.sh"

old_nginx_docker_opts="${NGINX_DOCKER_OPTS-__unset__}"
trap 'if [ "$old_nginx_docker_opts" = "__unset__" ]; then unset NGINX_DOCKER_OPTS; else NGINX_DOCKER_OPTS="$old_nginx_docker_opts"; fi' EXIT

NGINX_DOCKER_OPTS="--ulimit nofile=65535:65535"
choices_with_opts="$(__arg_choices_docker_opts "start-nginx")"
if ! grep -Fq "__CLEAR__|Clear current options" <<<"$choices_with_opts"; then
  echo "[Error] Expected clear choice when nginx docker opts are configured." >&2
  exit 1
fi

NGINX_DOCKER_OPTS=""
choices_without_opts="$(__arg_choices_docker_opts "start-nginx")"
if grep -Fq "__CLEAR__|Clear current options" <<<"$choices_without_opts"; then
  echo "[Error] Clear choice should not be shown when nginx docker opts are empty." >&2
  exit 1
fi

echo "start-nginx docker opts arg-choices checks passed."
