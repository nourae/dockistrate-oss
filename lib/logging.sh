# shellcheck shell=bash
#
# Loader for logging helpers.

LOGGING_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/logging" && pwd)"

if [ -f "${LOGGING_MODULE_DIR}/common.sh" ]; then
  source "${LOGGING_MODULE_DIR}/common.sh"
fi

for logging_file in "${LOGGING_MODULE_DIR}"/*.sh; do
  logging_basename="$(basename "${logging_file}")"
  if [ "${logging_basename}" = "common.sh" ]; then
    continue
  fi
  source "${logging_file}"
done
