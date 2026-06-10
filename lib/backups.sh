# shellcheck shell=bash
#
# Loader for backups functions.

BACKUPS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/backups" 2>/dev/null && pwd)"

if [ -z "${BACKUPS_MODULE_DIR:-}" ] || [ ! -d "${BACKUPS_MODULE_DIR}" ]; then
  echo "[Error] Missing backups module directory; reinstall or check repository layout." >&2
  exit 1
fi

source "${BACKUPS_MODULE_DIR}/common.sh"

for backups_file in "${BACKUPS_MODULE_DIR}"/*.sh; do
  backups_basename="$(basename "${backups_file}")"
  if [ "${backups_basename}" = "common.sh" ]; then
    continue
  fi
  source "${backups_file}"
done
