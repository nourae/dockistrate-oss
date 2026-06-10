#!/usr/bin/env bash

test_add_backend_client_cert_rejects_path_traversal() {
  local output status

  # Try adding a client with path traversal attempt
  output="$(run_dockistrate add-backend-client-cert mtls-test.example.com '../../../etc/passwd' 2>&1)"
  status=$?
  assertNotEquals "add-backend-client-cert should reject path traversal" 0 $status
  assertStringContains "error should mention invalid client name" "Invalid client name" "$output"
}

test_add_backend_client_cert_rejects_openssl_injection() {
  local output status

  # Try adding a client with OpenSSL subject injection attempt
  output="$(run_dockistrate add-backend-client-cert mtls-test.example.com '/CN=evil/O=bad' 2>&1)"
  status=$?
  assertNotEquals "add-backend-client-cert should reject slash" 0 $status
  assertStringContains "error should mention invalid client name" "Invalid client name" "$output"
}

test_add_backend_client_cert_accepts_valid_names() {
  local output status

  # Valid alphanumeric name
  output="$(run_dockistrate add-backend-client-cert mtls-test.example.com 'valid_client01' 2>&1)"
  # Note: may fail because mTLS not enabled, but not due to name validation
  assertTrue "error should NOT be about invalid client name" "[[ ! \"$output\" =~ 'Invalid client name' ]]"
}

test_is_valid_client_name_edge_cases() {
  # Source the mtls module to access the validation function directly
  # shellcheck source=/dev/null
  . "${ROOT_DIR}/lib/mtls.sh"

  # Test the validation function directly

  # Empty name should fail
  ! is_valid_client_name "" || fail "Empty name should be invalid"

  # Name starting with dot should fail
  ! is_valid_client_name ".hidden" || fail "Name starting with dot should be invalid"

  # Name ending with dot should fail
  ! is_valid_client_name "test." || fail "Name ending with dot should be invalid"

  # Name starting with hyphen should fail
  ! is_valid_client_name "-test" || fail "Name starting with hyphen should be invalid"

  # Double dots (path traversal) should fail
  ! is_valid_client_name "foo..bar" || fail "Double dots should be invalid"

  # Very long name should fail (>64 chars)
  ! is_valid_client_name "$(printf 'a%.0s' {1..65})" || fail "Very long name should be invalid"

  ! is_valid_client_name "client;rm -rf" || fail "Shell metacharacters should be invalid"
  ! is_valid_client_name 'client"test' || fail "Quotes should be invalid"
  ! is_valid_client_name 'client\test' || fail "Backslashes should be invalid"

  # Valid names should pass
  is_valid_client_name "client1" || fail "Valid alphanumeric name should be valid"
  is_valid_client_name "client_name" || fail "Name with underscore should be valid"
  is_valid_client_name "client-name" || fail "Name with hyphen should be valid"
  is_valid_client_name "client.device" || fail "Name with single dot should be valid"
  is_valid_client_name "CamelCase123" || fail "Mixed case alphanumeric should be valid"
}
