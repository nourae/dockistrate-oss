# shellcheck shell=bash
#
# Loader for ports functions.

PORTS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/ports" && pwd)"

if [ -f "${PORTS_MODULE_DIR}/common.sh" ]; then
  source "${PORTS_MODULE_DIR}/common.sh"
fi

for ports_file in "${PORTS_MODULE_DIR}"/*.sh; do
  ports_basename="$(basename "${ports_file}")"
  if [ "${ports_basename}" = "common.sh" ]; then
    continue
  fi
  source "${ports_file}"
done
