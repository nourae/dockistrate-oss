# shellcheck shell=bash
#
# Loader for entrypoint helper functions.

LOADER_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/loader" && pwd)"

if [ -f "${LOADER_MODULE_DIR}/common.sh" ]; then
  source "${LOADER_MODULE_DIR}/common.sh"
fi

for loader_file in "${LOADER_MODULE_DIR}"/*.sh; do
  loader_basename="$(basename "${loader_file}")"
  if [ "${loader_basename}" = "common.sh" ]; then
    continue
  fi
  source "${loader_file}"
done
