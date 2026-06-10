# shellcheck shell=bash
#
# Loader for clean uninstall functions.

CLEAN_UNINSTALL_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/clean_uninstall" && pwd)"

if [ -f "${CLEAN_UNINSTALL_MODULE_DIR}/common.sh" ]; then
  source "${CLEAN_UNINSTALL_MODULE_DIR}/common.sh"
fi

for clean_uninstall_file in "${CLEAN_UNINSTALL_MODULE_DIR}"/*.sh; do
  clean_uninstall_basename="$(basename "${clean_uninstall_file}")"
  if [ "${clean_uninstall_basename}" = "common.sh" ]; then
    continue
  fi
  source "${clean_uninstall_file}"
done
