# shellcheck shell=bash

function set_backup_compression() {
  local val="${1:-}"
  if [[ "$val" != "true" && "$val" != "false" ]]; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-backup-compression <true|false>" >&2
    return 1
  fi
  ENABLE_BACKUP_COMPRESSION="$val"
  save_config || return 1
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} ENABLE_BACKUP_COMPRESSION set to $val and saved in $GLOBAL_SETTINGS_FILE."
}
