#!/usr/bin/env bash
# Common stubs for regression tests to avoid docker dependencies and noisy logs.

STUBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stubs.d"
if [ -d "$STUBS_DIR" ]; then
  for stub_file in "$STUBS_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$stub_file"
  done
fi
