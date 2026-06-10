#!/usr/bin/env bash

test_acl_cidr_transition_guardrails() {
  local output status

  run_dockistrate add-backend acl-cidr.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-acl acl-cidr.test l7 allow 10.1.0.0/16 >/dev/null
  assertEquals "add-acl l7 cidr allow" 0 $?

  run_dockistrate set-acl-policy deny >/dev/null
  assertEquals "set-acl-policy deny baseline" 0 $?

  run_dockistrate set-acl-status 403 >/dev/null
  assertEquals "set-acl-status 403 baseline" 0 $?

  output="$(run_dockistrate set-acl-status 452)"
  status=$?
  assertNotEquals "set-acl-status should reject deny+cidr with non-403" 0 "$status"
  assertStringContains "set-acl-status guardrail message" "requires status 403" "$output"

  run_dockistrate set-acl-policy allow >/dev/null
  assertEquals "set-acl-policy allow" 0 $?

  run_dockistrate set-acl-status 452 >/dev/null
  assertEquals "set-acl-status non-403 when policy allow" 0 $?

  output="$(run_dockistrate set-acl-policy deny)"
  status=$?
  assertNotEquals "set-acl-policy deny should reject effective non-403 with cidr" 0 "$status"
  assertStringContains "set-acl-policy guardrail message" "requires status 403" "$output"

  output="$(run_dockistrate set-backend-acl-policy acl-cidr.test deny)"
  status=$?
  assertNotEquals "set-backend-acl-policy should reject non-403 with cidr" 0 "$status"
  assertStringContains "set-backend-acl-policy guardrail message" "requires status 403" "$output"

  run_dockistrate set-backend-acl-status acl-cidr.test 403 >/dev/null
  assertEquals "set-backend-acl-status 403" 0 $?

  run_dockistrate set-backend-acl-policy acl-cidr.test deny >/dev/null
  assertEquals "set-backend-acl-policy deny with 403 status" 0 $?

  output="$(run_dockistrate set-backend-acl-status acl-cidr.test 452)"
  status=$?
  assertNotEquals "set-backend-acl-status should reject deny+cidr with non-403" 0 "$status"
  assertStringContains "set-backend-acl-status guardrail message" "requires status 403" "$output"

  # Dedicated host with CIDR allow + inherited ACL should block backend policy transition.
  run_dockistrate add-backend acl-cidr-dh-policy.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend policy dedicated-host case" 0 $?
  run_dockistrate add-dedicated-host open.acl-cidr-dh-policy.test acl-cidr-dh-policy.test >/dev/null
  assertEquals "add-dedicated-host policy dedicated-host case" 0 $?
  run_dockistrate add-acl open.acl-cidr-dh-policy.test l7 allow 10.2.0.0/16 >/dev/null
  assertEquals "add-acl dedicated host cidr policy case" 0 $?
  run_dockistrate set-backend-acl-status acl-cidr-dh-policy.test 452 >/dev/null
  assertEquals "set-backend-acl-status baseline policy dedicated-host case" 0 $?
  output="$(run_dockistrate set-backend-acl-policy acl-cidr-dh-policy.test deny)"
  status=$?
  assertNotEquals "set-backend-acl-policy should reject inherited dedicated-host cidr" 0 "$status"
  assertStringContains "set-backend-acl-policy dedicated-host guardrail message" "open.acl-cidr-dh-policy.test" "$output"

  # Dedicated host with CIDR allow + inherited ACL should block backend status transition.
  run_dockistrate add-backend acl-cidr-dh-status.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend status dedicated-host case" 0 $?
  run_dockistrate add-dedicated-host open.acl-cidr-dh-status.test acl-cidr-dh-status.test >/dev/null
  assertEquals "add-dedicated-host status dedicated-host case" 0 $?
  run_dockistrate add-acl open.acl-cidr-dh-status.test l7 allow 10.3.0.0/16 >/dev/null
  assertEquals "add-acl dedicated host cidr status case" 0 $?
  run_dockistrate set-backend-acl-status acl-cidr-dh-status.test 403 >/dev/null
  assertEquals "set-backend-acl-status 403 status dedicated-host case" 0 $?
  run_dockistrate set-backend-acl-policy acl-cidr-dh-status.test deny >/dev/null
  assertEquals "set-backend-acl-policy deny status dedicated-host case" 0 $?
  output="$(run_dockistrate set-backend-acl-status acl-cidr-dh-status.test 452)"
  status=$?
  assertNotEquals "set-backend-acl-status should reject inherited dedicated-host cidr" 0 "$status"
  assertStringContains "set-backend-acl-status dedicated-host guardrail message" "open.acl-cidr-dh-status.test" "$output"

  # Dedicated host with inherit_acl=no should not block backend transitions.
  run_dockistrate add-backend acl-cidr-dh-noinherit.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend noinherit case" 0 $?
  run_dockistrate add-dedicated-host open.acl-cidr-dh-noinherit.test acl-cidr-dh-noinherit.test yes no yes yes yes >/dev/null
  assertEquals "add-dedicated-host noinherit case" 0 $?
  run_dockistrate add-acl open.acl-cidr-dh-noinherit.test l7 allow 10.4.0.0/16 >/dev/null
  assertEquals "add-acl dedicated host cidr noinherit case" 0 $?
  run_dockistrate set-backend-acl-status acl-cidr-dh-noinherit.test 452 >/dev/null
  assertEquals "set-backend-acl-status noinherit case" 0 $?
  run_dockistrate set-backend-acl-policy acl-cidr-dh-noinherit.test deny >/dev/null
  assertEquals "set-backend-acl-policy should pass when dedicated host does not inherit ACL" 0 $?
  output="$(run_dockistrate set-backend-acl-status acl-cidr-dh-noinherit.test 452)"
  status=$?
  assertEquals "set-backend-acl-status should pass when dedicated host does not inherit ACL" 0 "$status"

  # Dedicated host with explicit non-CIDR ACL rows should not falsely block backend transitions.
  run_dockistrate add-backend acl-cidr-dh-explicit.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend explicit acl rows case" 0 $?
  run_dockistrate add-dedicated-host open.acl-cidr-dh-explicit.test acl-cidr-dh-explicit.test >/dev/null
  assertEquals "add-dedicated-host explicit acl rows case" 0 $?
  run_dockistrate add-acl open.acl-cidr-dh-explicit.test l7 allow 192.0.2.25 >/dev/null
  assertEquals "add-acl dedicated host exact ip explicit case" 0 $?
  run_dockistrate set-backend-acl-status acl-cidr-dh-explicit.test 452 >/dev/null
  assertEquals "set-backend-acl-status explicit acl rows case" 0 $?
  output="$(run_dockistrate set-backend-acl-policy acl-cidr-dh-explicit.test deny)"
  status=$?
  assertEquals "set-backend-acl-policy should not fail with non-CIDR dedicated ACL rows" 0 "$status"
}
