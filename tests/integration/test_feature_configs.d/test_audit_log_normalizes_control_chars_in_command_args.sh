#!/usr/bin/env bash

test_audit_log_normalizes_control_chars_in_command_args() {
  rm -f "${LOG_DIR}/audit.log"

  local noisy_arg output status
  noisy_arg="$(printf 'alpha\nbeta\tgamma\rdelta')"
  output="$(run_dockistrate status "$noisy_arg" 2>&1)"
  status=$?

  assertEquals "status command should succeed with control-char argument input" 0 "$status"
  assertStringContains "status output should still render normal output" "=== Nginx Proxy Container ===" "$output"

  local line_count
  line_count="$(wc -l <"${LOG_DIR}/audit.log" 2>/dev/null || echo 0)"
  line_count="${line_count//[[:space:]]/}"
  assertEquals "audit log should keep one line for the command audit entry" "1" "$line_count"
  assertTrue "audit log should contain flattened single-line argument text" \
    "grep -Fq 'status alpha beta gamma delta' '${LOG_DIR}/audit.log'"
}
