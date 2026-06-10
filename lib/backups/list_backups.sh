# shellcheck shell=bash

function list_backups() {
  _backup_ensure_runtime_defaults
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "[Info] No backups directory found."
    return
  fi
  echo "[Info] Available backups (sorted ascending):"
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -print 2>/dev/null |
    while IFS= read -r backup_item; do
      case "$(basename "$backup_item")" in
      *.sha256) continue ;;
      esac
      basename "$backup_item"
    done |
    LC_ALL=C sort
}
