# shellcheck shell=bash
#
# Loader for nginx functions.

NGINX_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/nginx" && pwd)"

if [ -f "${NGINX_MODULE_DIR}/common.sh" ]; then
  source "${NGINX_MODULE_DIR}/common.sh"
fi

for nginx_file in "${NGINX_MODULE_DIR}"/*.sh; do
  nginx_basename="$(basename "${nginx_file}")"
  if [ "${nginx_basename}" = "common.sh" ]; then
    continue
  fi
  source "${nginx_file}"
done
