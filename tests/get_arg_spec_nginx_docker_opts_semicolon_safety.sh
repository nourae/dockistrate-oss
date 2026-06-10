#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/get_arg_spec.sh
source "$ROOT_DIR/lib/cli/get_arg_spec.sh"

old_nginx_image="${NGINX_IMAGE-__unset__}"
old_nginx_docker_opts="${NGINX_DOCKER_OPTS-__unset__}"
trap '
if [ "$old_nginx_image" = "__unset__" ]; then
  unset NGINX_IMAGE
else
  NGINX_IMAGE="$old_nginx_image"
fi
if [ "$old_nginx_docker_opts" = "__unset__" ]; then
  unset NGINX_DOCKER_OPTS
else
  NGINX_DOCKER_OPTS="$old_nginx_docker_opts"
fi
' EXIT

NGINX_IMAGE="nginx:1.28.1"
NGINX_DOCKER_OPTS="--env 'JAVA_OPTS=a;b' --label 'note=x;y'"

start_spec="$(get_arg_spec "start-nginx")"
cli_parse_arg_spec "$start_spec"

if [ "${#CLI_SPEC_NAMES[@]}" -ne 2 ]; then
  echo "[Error] start-nginx arg spec should parse into exactly 2 args." >&2
  exit 1
fi
if [ "${CLI_SPEC_NAMES[0]}" != "nginx_image" ] || [ "${CLI_SPEC_NAMES[1]}" != "docker_opts" ]; then
  echo "[Error] start-nginx arg names parsed incorrectly: ${CLI_SPEC_NAMES[*]}" >&2
  exit 1
fi
if [ "${CLI_SPEC_DEFAULTS[0]}" != "$NGINX_IMAGE" ]; then
  echo "[Error] start-nginx nginx_image default mismatch." >&2
  exit 1
fi
if [ -n "${CLI_SPEC_DEFAULTS[1]}" ]; then
  echo "[Error] start-nginx docker_opts default must be empty in arg spec to stay semicolon-safe." >&2
  exit 1
fi

set_spec="$(get_arg_spec "set-nginx-docker-opts")"
cli_parse_arg_spec "$set_spec"

if [ "${#CLI_SPEC_NAMES[@]}" -ne 1 ]; then
  echo "[Error] set-nginx-docker-opts arg spec should parse into exactly 1 arg." >&2
  exit 1
fi
if [ "${CLI_SPEC_NAMES[0]}" != "docker_opts" ]; then
  echo "[Error] set-nginx-docker-opts arg name parsed incorrectly: ${CLI_SPEC_NAMES[*]}" >&2
  exit 1
fi
if [ -n "${CLI_SPEC_DEFAULTS[0]}" ]; then
  echo "[Error] set-nginx-docker-opts default must be empty in arg spec to stay semicolon-safe." >&2
  exit 1
fi

fix_permissions_spec="$(get_arg_spec "fix-permissions")"
cli_parse_arg_spec "$fix_permissions_spec"

if [ "${#CLI_SPEC_NAMES[@]}" -ne 1 ]; then
  echo "[Error] fix-permissions arg spec should parse into exactly 1 optional mode arg." >&2
  exit 1
fi
if [ "${CLI_SPEC_NAMES[0]}" != "mode" ] || [ "${CLI_SPEC_DEFAULTS[0]}" != "__DEFAULT__" ]; then
  echo "[Error] fix-permissions arg spec should expose default mode selection." >&2
  exit 1
fi

echo "nginx docker opts arg-spec semicolon-safety checks passed."
