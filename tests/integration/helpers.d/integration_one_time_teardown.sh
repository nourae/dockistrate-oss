#!/usr/bin/env bash

function integration_one_time_teardown() {
  if [ "${INTEGRATION_OWNS_STATE_DIR:-false}" = "true" ]; then
    rm -rf "${STATE_DIR:?}"
  else
    integration_reset_workdir
  fi
}
