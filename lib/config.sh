# shellcheck shell=bash
#
# Loader for config functions.

CONFIG_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/config" && pwd)"

if ! declare -F __dockistrate_runtime_paths_loaded >/dev/null 2>&1; then
  # shellcheck source=./runtime_paths.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime_paths.sh"
fi

source "${CONFIG_MODULE_DIR}/schema_version.sh"
source "${CONFIG_MODULE_DIR}/common.sh"

for config_file in "${CONFIG_MODULE_DIR}"/*.sh; do
  config_basename="$(basename "${config_file}")"
  if [ "${config_basename}" = "common.sh" ] || [ "${config_basename}" = "schema_version.sh" ]; then
    continue
  fi
  source "${config_file}"
done
