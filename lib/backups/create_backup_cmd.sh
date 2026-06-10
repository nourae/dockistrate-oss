# shellcheck shell=bash

function create_backup_cmd() {
  local desc="${1:-}"
  create_backup "ForceManual" "${desc:-ManualBackup}"
}
