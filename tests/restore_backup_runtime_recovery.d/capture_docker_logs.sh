#!/usr/bin/env bash

function capture_docker_logs() {
  _restore_trace_append "capture_docker_logs"
  [ "${STUB_CAPTURE_DOCKER_LOGS_FAIL:-false}" != "true" ]
}
