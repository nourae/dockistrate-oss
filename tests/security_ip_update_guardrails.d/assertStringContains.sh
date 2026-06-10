#!/usr/bin/env bash

assertStringContains() {
  local message="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${message}: expected to find '${needle}' in output:\n${haystack}"
  fi
}
