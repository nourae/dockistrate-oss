# shellcheck shell=bash

function set_backup_retention() {
  local days="${1:-}"
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-backup-retention <days> (integer, 0 = keep forever)" >&2
    return 1
  fi
  BACKUP_RETENTION="$days"
  save_config || return 1
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} BACKUP_RETENTION set to $days and saved in $GLOBAL_SETTINGS_FILE."
}
