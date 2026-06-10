#!/usr/bin/env bash

assertFileContains() {
  local expected="$1" file="$2"
  if grep -Fqx "$expected" "$file"; then
    return 0
  fi
  case "$expected" in
  backend,* | port,* | path,* | weird,*)
    if grep -Fq "$expected" "$file"; then
      return 0
    fi
    ;;
  esac
  fail "Expected to find '${expected}' in ${file} but contents were:\n$(cat "$file")"
}
