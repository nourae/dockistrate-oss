#!/usr/bin/env bash

assertFileContainsSubstring() {
  local expected="$1" file="$2"
  if ! grep -Fq "$expected" "$file"; then
    fail "Expected to find substring '${expected}' in ${file} but contents were:\n$(cat "$file")"
  fi
}
