# shellcheck shell=bash
#
# Loader for permissions functions.

PERMISSIONS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/permissions" && pwd)"

if [ -f "${PERMISSIONS_MODULE_DIR}/common.sh" ]; then
  source "${PERMISSIONS_MODULE_DIR}/common.sh"
fi

for permissions_file in "${PERMISSIONS_MODULE_DIR}"/*.sh; do
  permissions_basename="$(basename "${permissions_file}")"
  if [ "${permissions_basename}" = "common.sh" ]; then
    continue
  fi
  source "${permissions_file}"
done
