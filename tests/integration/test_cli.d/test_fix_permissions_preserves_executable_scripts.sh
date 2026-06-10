#!/usr/bin/env bash

test_fix_permissions_preserves_executable_scripts() {
  local scripts=(
    "${ROOT_DIR}/tests/run.sh"
    "${ROOT_DIR}/scripts/update-function-reference-appendices.sh"
    "${ROOT_DIR}/scripts/render-function-reference-html.sh"
    "${ROOT_DIR}/tests/remove_backend_escaping.sh"
    "${ROOT_DIR}/tests/docker_opts_parsing.sh"
    "${ROOT_DIR}/tests/clean_all_regression.sh"
    "${ROOT_DIR}/tests/certs_timestamp.sh"
    "${ROOT_DIR}/tests/integration/test_cli.sh"
    "${ROOT_DIR}/tests/integration/test_feature_configs.sh"
    "${ROOT_DIR}/tests/mocks/docker"
  )

  local script
  for script in "${scripts[@]}"; do
    if [ -f "$script" ]; then
      chmod 644 "$script"
      assertTrue "${script} should be non-executable before fix" "[ ! -x '$script' ]"
    fi
  done

  local output status
  output="$(run_dockistrate fix-permissions)"
  status=$?

  assertEquals "fix-permissions should succeed" 0 $status
  assertStringContains "fix-permissions output mentions completion" "Permissions normalization complete" "$output"

  for script in "${scripts[@]}"; do
    if [ -f "$script" ]; then
      assertTrue "${script} should be executable after fix" "[ -x '$script' ]"
    fi
  done
}
