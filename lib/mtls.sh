# shellcheck shell=bash
#
# Loader for mtls functions.

MTLS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/mtls" && pwd)"

if [ -f "${MTLS_MODULE_DIR}/common.sh" ]; then
  source "${MTLS_MODULE_DIR}/common.sh"
fi

for mtls_file in "${MTLS_MODULE_DIR}"/*.sh; do
  mtls_basename="$(basename "${mtls_file}")"
  if [ "${mtls_basename}" = "common.sh" ]; then
    continue
  fi
  source "${mtls_file}"
done
