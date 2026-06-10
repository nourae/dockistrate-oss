# shellcheck shell=bash
#
# Loader for utility helper functions.

UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/utils" && pwd)"

if ! declare -F __dockistrate_runtime_paths_loaded >/dev/null 2>&1; then
  # shellcheck source=./runtime_paths.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/runtime_paths.sh"
fi

source "${UTILS_DIR}/common.sh"

for utils_file in "${UTILS_DIR}"/*.sh; do
  utils_basename="$(basename "$utils_file")"
  if [ "$utils_basename" = "common.sh" ]; then
    continue
  fi
  source "$utils_file"
done
