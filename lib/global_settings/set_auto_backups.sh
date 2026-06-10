# shellcheck shell=bash

function set_auto_backups() {
  local val="${1:-}"
  if [[ "$val" != "true" && "$val" != "false" ]]; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-auto-backups <true|false>" >&2
    return 1
  fi
  ENABLE_AUTO_BACKUPS="$val"
  save_config || return 1
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} ENABLE_AUTO_BACKUPS set to $val and saved in $GLOBAL_SETTINGS_FILE."
}
