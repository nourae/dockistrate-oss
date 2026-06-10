# shellcheck shell=bash
#
# Loader for dependencies functions.

DEPENDENCIES_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/dependencies" && pwd)"

if [ -f "${DEPENDENCIES_MODULE_DIR}/common.sh" ]; then
  source "${DEPENDENCIES_MODULE_DIR}/common.sh"
fi

for dependencies_file in "${DEPENDENCIES_MODULE_DIR}"/*.sh; do
  dependencies_basename="$(basename "${dependencies_file}")"
  if [ "${dependencies_basename}" = "common.sh" ]; then
    continue
  fi
  source "${dependencies_file}"
done
