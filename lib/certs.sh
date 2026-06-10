# shellcheck shell=bash
#
# Loader for certs functions.

CERTS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/certs" 2>/dev/null && pwd)"

if [ -z "${CERTS_MODULE_DIR:-}" ] || [ ! -d "${CERTS_MODULE_DIR}" ]; then
  echo "[Error] Missing certs module directory; reinstall or check repository layout." >&2
  exit 1
fi

if [ -f "${CERTS_MODULE_DIR}/common.sh" ]; then
  source "${CERTS_MODULE_DIR}/common.sh"
fi

for certs_file in "${CERTS_MODULE_DIR}"/*.sh; do
  certs_basename="$(basename "${certs_file}")"
  if [ "${certs_basename}" = "common.sh" ]; then
    continue
  fi
  source "${certs_file}"
done
