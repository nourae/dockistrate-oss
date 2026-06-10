# shellcheck shell=bash
#
# Loader for http version functions.

HTTP_VERSION_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/http_version" && pwd)"

if [ -f "${HTTP_VERSION_MODULE_DIR}/common.sh" ]; then
  source "${HTTP_VERSION_MODULE_DIR}/common.sh"
fi

for http_version_file in "${HTTP_VERSION_MODULE_DIR}"/*.sh; do
  http_version_basename="$(basename "${http_version_file}")"
  if [ "${http_version_basename}" = "common.sh" ]; then
    continue
  fi
  source "${http_version_file}"
done
