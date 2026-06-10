# shellcheck shell=bash
#
# Loader for security rules functions.

SECURITY_RULES_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/security_rules" && pwd)"

function __dockistrate_security_rules_loaded() {
  :
}

if [ -f "${SECURITY_RULES_MODULE_DIR}/common.sh" ]; then
  source "${SECURITY_RULES_MODULE_DIR}/common.sh"
fi

for security_rules_file in "${SECURITY_RULES_MODULE_DIR}"/*.sh; do
  security_rules_basename="$(basename "${security_rules_file}")"
  if [ "${security_rules_basename}" = "common.sh" ]; then
    continue
  fi
  source "${security_rules_file}"
done
