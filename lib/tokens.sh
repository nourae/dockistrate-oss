# shellcheck shell=bash
#
# Loader for tokens functions.

TOKENS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/tokens" && pwd)"

if [ -f "${TOKENS_MODULE_DIR}/common.sh" ]; then
  source "${TOKENS_MODULE_DIR}/common.sh"
fi

for tokens_file in "${TOKENS_MODULE_DIR}"/*.sh; do
  tokens_basename="$(basename "${tokens_file}")"
  if [ "${tokens_basename}" = "common.sh" ]; then
    continue
  fi
  source "${tokens_file}"
done
