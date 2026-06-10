#!/usr/bin/env bash

test_add_backend_rejects_missing_option_values_without_unbound_failures() {
  local flag output status safe_flag domain

  for flag in --listen --cert --ws --docker-opts --network --expose; do
    safe_flag="$(printf '%s' "$flag" | tr -cd '[:alnum:]')"
    domain="missing-${safe_flag}.test"
    output="$(run_dockistrate add-backend "$domain" nginx:alpine 18180 http "$flag" 2>&1)"
    status=$?

    assertNotEquals "add-backend ${flag} should fail when value is missing" 0 "$status"
    assertStringContains "add-backend ${flag} should explain missing value" "${flag} requires a value" "$output"
    assertTrue "add-backend ${flag} should not hit set -u unbound variable failure" \
      "[[ \"$output\" != *\"unbound variable\"* ]]"
  done
}

test_adjacent_option_parsers_reject_missing_values_without_unbound_failures() {
  local domain="missing-adjacent-options.test"
  local output status

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed backend" 0 $?
  run_dockistrate add-acl "$domain" l7 allow 127.0.0.1 >/dev/null
  assertEquals "seed acl" 0 $?

  output="$(run_dockistrate update-backend "$domain" --image 2>&1)"
  status=$?
  assertNotEquals "update-backend should reject missing --image value" 0 "$status"
  assertStringContains "update-backend missing value" "--image requires a value" "$output"
  assertTrue "update-backend should not hit unbound variable failure" "[[ \"$output\" != *\"unbound variable\"* ]]"

  output="$(run_dockistrate update-port "$domain" --nginx-port 2>&1)"
  status=$?
  assertNotEquals "update-port should reject missing --nginx-port value" 0 "$status"
  assertStringContains "update-port missing value" "--nginx-port requires a value" "$output"
  assertTrue "update-port should not hit unbound variable failure" "[[ \"$output\" != *\"unbound variable\"* ]]"

  output="$(run_dockistrate add-port "$domain" 8080 18180 http none no --http3 2>&1)"
  status=$?
  assertNotEquals "add-port should reject missing --http3 value" 0 "$status"
  assertStringContains "add-port missing value" "--http3 requires a value" "$output"
  assertTrue "add-port should not hit unbound variable failure" "[[ \"$output\" != *\"unbound variable\"* ]]"

  output="$(run_dockistrate add-security-rule "$domain" 1 header User-Agent equals ok --code 2>&1)"
  status=$?
  assertNotEquals "add-security-rule should reject missing --code value" 0 "$status"
  assertStringContains "add-security-rule missing value" "--code requires a value" "$output"
  assertTrue "add-security-rule should not hit unbound variable failure" "[[ \"$output\" != *\"unbound variable\"* ]]"

  output="$(run_dockistrate update-acl 1 --ip 2>&1)"
  status=$?
  assertNotEquals "update-acl should reject missing --ip value" 0 "$status"
  assertStringContains "update-acl missing value" "--ip requires a value" "$output"
  assertTrue "update-acl should not hit unbound variable failure" "[[ \"$output\" != *\"unbound variable\"* ]]"
}
