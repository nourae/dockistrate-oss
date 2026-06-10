# shellcheck shell=bash
#
# Loader for headers functions.

HEADERS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/headers" && pwd)"

if [ -f "${HEADERS_MODULE_DIR}/common.sh" ]; then
  source "${HEADERS_MODULE_DIR}/common.sh"
fi

for headers_file in "${HEADERS_MODULE_DIR}"/*.sh; do
  headers_basename="$(basename "${headers_file}")"
  if [ "${headers_basename}" = "common.sh" ]; then
    continue
  fi
  source "${headers_file}"
done
