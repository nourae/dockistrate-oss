#!/usr/bin/env bash

function integration_reset_workdir() {
  rm -rf "${STATE_DIR:?}"
  mkdir -p "${CONFIG_DIR}" "${CERTS_DIR}" "${BACKUP_DIR}"
  # Keep rollback snapshots enabled, but reserve full automatic payload copies
  # for the explicit backup smoke cases and domain_config_auto_backup/backup_restore tests.
  printf '5\n' >"${CONFIG_DIR}/state_schema_version"
  integration_global_csv_seed "${CONFIG_DIR}/global_settings.csv" ENABLE_AUTO_BACKUPS false
}
