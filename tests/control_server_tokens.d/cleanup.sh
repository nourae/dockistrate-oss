#!/usr/bin/env bash

cleanup() {
  rm -rf "$CONF_D_DIR"
  if [ -d "$RESTORE_DIR" ]; then
    mv "$RESTORE_DIR" "$CONF_D_DIR"
  fi
  rm -rf "$TMP_DIR"
  rm -f "${BACKUP_DIR}/"*ServerTokens_*.tar.gz
}
