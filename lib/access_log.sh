# shellcheck shell=bash
#
# Loader for access log functions.

ACCESS_LOG_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/access_log" && pwd)"

function __dockistrate_access_log_loaded() {
  :
}

if [ -f "${ACCESS_LOG_MODULE_DIR}/common.sh" ]; then
  source "${ACCESS_LOG_MODULE_DIR}/common.sh"
fi

for access_log_file in "${ACCESS_LOG_MODULE_DIR}"/*.sh; do
  access_log_basename="$(basename "${access_log_file}")"
  if [ "${access_log_basename}" = "common.sh" ]; then
    continue
  fi
  source "${access_log_file}"
done
