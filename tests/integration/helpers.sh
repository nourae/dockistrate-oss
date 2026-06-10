#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MOCK_BIN_DIR="${ROOT_DIR}/tests/mocks"
SHUNIT2="${ROOT_DIR}/tests/lib/shunit2"

STATE_DIR="${ROOT_DIR}/state"
INTEGRATION_OWNS_STATE_DIR="false"

CONFIG_DIR="${STATE_DIR}/config"
CERTS_DIR="${STATE_DIR}/certs"
BACKUP_DIR="${STATE_DIR}/backups"
LOG_DIR="${STATE_DIR}/logs"
CAPTURE_DIR="${STATE_DIR}/pcaps"
TMP_DIR="${STATE_DIR}/tmp"

INTEGRATION_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "${INTEGRATION_HELPERS_DIR}/helpers.d" ]; then
  for helper_file in "${INTEGRATION_HELPERS_DIR}/helpers.d"/*.sh; do
    # shellcheck disable=SC1090
    . "$helper_file"
  done
fi
