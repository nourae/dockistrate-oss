# shellcheck shell=bash
#
# Loader for capture functions.

CAPTURE_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/capture" && pwd)"

if [ -f "${CAPTURE_MODULE_DIR}/common.sh" ]; then
  source "${CAPTURE_MODULE_DIR}/common.sh"
fi

for capture_file in "${CAPTURE_MODULE_DIR}"/*.sh; do
  capture_basename="$(basename "${capture_file}")"
  if [ "${capture_basename}" = "common.sh" ]; then
    continue
  fi
  source "${capture_file}"
done
