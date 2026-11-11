# shellcheck shell=bash

# Source-only loader: discovery and completion must never prepare live state.
DOMAIN_CONFIG_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/domain_config" && pwd)"
source "${DOMAIN_CONFIG_MODULE_DIR}/common.sh"
for domain_config_module in "${DOMAIN_CONFIG_MODULE_DIR}"/*.sh; do
  [ "${domain_config_module##*/}" != common.sh ] || continue
  source "$domain_config_module"
done

function __dockistrate_domain_config_loaded() { :; }
