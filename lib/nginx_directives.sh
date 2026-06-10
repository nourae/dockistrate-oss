# shellcheck shell=bash
#
# Loader for nginx directive engine functions.

NGINX_DIRECTIVES_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/nginx_directives" && pwd)"

if [ -f "${NGINX_DIRECTIVES_MODULE_DIR}/common.sh" ]; then
  source "${NGINX_DIRECTIVES_MODULE_DIR}/common.sh"
fi

for nginx_directives_file in "${NGINX_DIRECTIVES_MODULE_DIR}"/*.sh; do
  nginx_directives_basename="$(basename "${nginx_directives_file}")"
  if [ "${nginx_directives_basename}" = "common.sh" ]; then
    continue
  fi
  source "${nginx_directives_file}"
done
