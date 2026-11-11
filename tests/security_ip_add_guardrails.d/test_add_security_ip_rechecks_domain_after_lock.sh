#!/usr/bin/env bash

test_add_security_ip_rechecks_domain_after_lock() {
  local before output status backend_snapshot rollback_marker
  before="$(cat "$SECURITY_IP_RULES_DB")"
  backend_snapshot="$TMP_ROOT/backend_ports.before_acl_race.csv"
  rollback_marker="$TMP_ROOT/acl_race_rollback.called"
  cp "$BACKEND_PORTS_FILE" "$backend_snapshot"
  rm -f "$rollback_marker"

  function _config_begin_return_transaction_if_needed() {
    local __started_var="${1:-}"
    printf -v "$__started_var" '%s' "true"
    printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  }

  function transaction_return_failure() {
    : >"$rollback_marker"
    return 1
  }

  output="$( (add_security_ip example.com l7 allow 192.0.2.70) 2>&1)"
  status=$?

  # Restore the shared harness before asserting so later tests use the real
  # transaction helpers even when this regression fails.
  cp "$backend_snapshot" "$BACKEND_PORTS_FILE"
  # shellcheck disable=SC1091
  source "$ROOT_DIR/lib/backups/common.sh"

  assertTrue "add-security-ip should fail when its backend disappears after locking" "[ $status -ne 0 ]"
  assertStringContains "post-lock ACL domain error" \
    "[Error] Domain 'example.com' was removed before the ACL rule could be saved." "$output"
  assertTrue "post-lock ACL domain failure should invoke rollback" "[ -f '$rollback_marker' ]"
  assertEquals "post-lock ACL domain failure should not mutate state" "$before" "$(cat "$SECURITY_IP_RULES_DB")"
}
