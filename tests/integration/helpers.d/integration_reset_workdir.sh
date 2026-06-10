#!/usr/bin/env bash

function integration_reset_workdir() {
  rm -rf "${STATE_DIR:?}"
  mkdir -p "${CONFIG_DIR}" "${CERTS_DIR}" "${BACKUP_DIR}"
}
