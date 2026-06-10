# shellcheck shell=bash
#
# Loader for tls functions.

TLS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/tls" && pwd)"

if [ -f "${TLS_MODULE_DIR}/common.sh" ]; then
  source "${TLS_MODULE_DIR}/common.sh"
fi

for tls_file in "${TLS_MODULE_DIR}"/*.sh; do
  tls_basename="$(basename "${tls_file}")"
  if [ "${tls_basename}" = "common.sh" ]; then
    continue
  fi
  source "${tls_file}"
done
