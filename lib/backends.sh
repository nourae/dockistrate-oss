# shellcheck shell=bash
#
# Loader for backend management functions.

BACKENDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/backends" && pwd)"

if [ -f "${BACKENDS_DIR}/common.sh" ]; then
  source "${BACKENDS_DIR}/common.sh"
fi

for backend_file in "${BACKENDS_DIR}"/*.sh; do
  backend_basename="$(basename "$backend_file")"
  if [ "$backend_basename" = "common.sh" ]; then
    continue
  fi
  source "$backend_file"
done
