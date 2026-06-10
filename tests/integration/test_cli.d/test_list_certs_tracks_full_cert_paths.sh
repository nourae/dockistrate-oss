#!/usr/bin/env bash

test_list_certs_tracks_full_cert_paths() {
  run_dockistrate add-cert example.com 443 selfsigned >/dev/null
  assertEquals "seed example.com_443 cert" 0 $?

  run_dockistrate add-cert example.com 4430 selfsigned >/dev/null
  assertEquals "seed example.com_4430 cert" 0 $?

  run_dockistrate add-backend example.com nginx:alpine 9000 http >/dev/null
  assertEquals "seed backend for example.com" 0 $?

  run_dockistrate add-port example.com 4430 9000 https selfsigned/live/example.com_4430 >/dev/null
  assertEquals "map https port for example.com" 0 $?

  local output
  output="$(run_dockistrate list-certs)"
  assertEquals "list-certs should succeed" 0 $?

  local line_443 line_4430
  line_443="$(printf '%s\n' "$output" | grep -E 'example\.com_443[[:space:]]*\|' || true)"
  line_4430="$(printf '%s\n' "$output" | grep -E 'example\.com_4430[[:space:]]*\|' || true)"

  if [ -z "$line_443" ] || [ -z "$line_4430" ]; then
    fail "list-certs output missing expected entries:\n${output}"
  fi

  local in_use_443 in_use_4430
  in_use_443="$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $NF); print $NF}' <<<"$line_443")"
  in_use_4430="$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $NF); print $NF}' <<<"$line_4430")"

  assertEquals "example.com_443 cert should not be marked in use" "No" "$in_use_443"
  assertEquals "example.com_4430 cert should be marked in use" "Yes" "$in_use_4430"
}
