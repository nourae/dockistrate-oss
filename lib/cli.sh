# shellcheck shell=bash
#
# Loader for CLI/interactive functions.

CLI_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/cli" && pwd)"

if [ -f "${CLI_MODULE_DIR}/common.sh" ]; then
  source "${CLI_MODULE_DIR}/common.sh"
fi
if ! declare -F _set_command_description >/dev/null 2>&1; then
  source "${CLI_MODULE_DIR}/_set_command_description.sh"
fi

for cli_file in "${CLI_MODULE_DIR}"/*.sh; do
  cli_basename="$(basename "${cli_file}")"
  if [ "${cli_basename}" = "common.sh" ] || [ "${cli_basename}" = "_set_command_description.sh" ]; then
    continue
  fi
  source "${cli_file}"
done
