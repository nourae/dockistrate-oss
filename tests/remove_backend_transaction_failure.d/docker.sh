#!/usr/bin/env bash

function docker() {
  if [ "${1:-}" = "rm" ]; then
    return 1
  fi
  return 0
}
