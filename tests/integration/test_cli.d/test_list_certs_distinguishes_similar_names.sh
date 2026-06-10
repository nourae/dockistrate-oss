#!/usr/bin/env bash

test_list_certs_distinguishes_similar_names() {
  local output

  output="$(run_dockistrate add-backend example.com nginx:alpine 18180 http)"
  assertEquals "seed backend with http port" 0 $?

  output="$(run_dockistrate add-backend examplex.com nginx:alpine 8443 https)"
  assertEquals "seed backend with https port" 0 $?

  output="$(CERT_AUTOCONFIG_DISABLED=1 run_dockistrate add-cert example.com 443 selfsigned)"
  assertEquals "seed standalone cert" 0 $?

  output="$(run_dockistrate list-certs)"
  assertEquals "list-certs should succeed" 0 $?

  local example_line examplex_line
  example_line="$(printf '%s\n' "$output" | grep -F 'example.com_443' || true)"
  examplex_line="$(printf '%s\n' "$output" | grep -F 'examplex.com_443' || true)"

  if [ -z "$example_line" ] || [ -z "$examplex_line" ]; then
    fail "list-certs output did not include expected certificate entries:\n${output}"
  fi

  local example_in_use examplex_in_use
  example_in_use="$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $NF); print $NF}' <<<"$example_line")"
  examplex_in_use="$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $NF); print $NF}' <<<"$examplex_line")"

  assertEquals "example.com cert should not be marked in use" "No" "$example_in_use"
  assertEquals "examplex.com cert should be marked in use" "Yes" "$examplex_in_use"
}
