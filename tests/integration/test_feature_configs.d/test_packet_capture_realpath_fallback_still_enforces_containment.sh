#!/usr/bin/env bash

test_packet_capture_realpath_fallback_still_enforces_containment() {
  local shim_dir="${STATE_DIR}/realpath-fallback-shim"
  local shim_realpath="${shim_dir}/realpath"
  local old_path="$PATH"
  mkdir -p "$shim_dir"
  cat >"$shim_realpath" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod 755 "$shim_realpath"

  local nested_rel="pcaps/fallback_nested/with/missing"
  local nested_abs="${CAPTURE_DIR}/fallback_nested/with/missing"
  rm -rf "${CAPTURE_DIR}/fallback_nested"
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for realpath fallback capture" 0 $?

  local output status
  PATH="${shim_dir}:$old_path"
  output="$(run_dockistrate start-capture "$nested_rel")"
  status=$?
  PATH="$old_path"
  assertEquals "start-capture should still create nested directories when realpath fallback is active" 0 "$status"
  assertTrue "nested path should be created under CAPTURE_DIR during fallback mode" "[ -d '${nested_abs}' ]"

  local stop_output stop_status
  stop_output="$(DOCKER_MOCK_PS_NAMES='nginx-capture' run_dockistrate stop-capture)"
  stop_status=$?
  assertEquals "stop-capture should succeed after fallback-mode capture" 0 "$stop_status"
  assertStringContains "stop-capture message" "Packet capture stopped" "$stop_output"

  PATH="${shim_dir}:$old_path"
  output="$(run_dockistrate start-capture pcaps/../../escape_fallback)"
  status=$?
  PATH="$old_path"
  assertNotEquals "start-capture should reject traversal outside CAPTURE_DIR during fallback mode" 0 "$status"
  assertStringContains "fallback traversal error should mention capture root containment" \
    "must reside within '${CAPTURE_DIR}'" "$output"
}
