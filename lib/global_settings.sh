# shellcheck shell=bash
#
# Loader for global settings functions.

GLOBAL_SETTINGS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/global_settings" && pwd)"

source "${GLOBAL_SETTINGS_MODULE_DIR}/common.sh"

for global_settings_file in "${GLOBAL_SETTINGS_MODULE_DIR}"/*.sh; do
  global_settings_basename="$(basename "${global_settings_file}")"
  if [ "${global_settings_basename}" = "common.sh" ]; then
    continue
  fi
  source "${global_settings_file}"
done
