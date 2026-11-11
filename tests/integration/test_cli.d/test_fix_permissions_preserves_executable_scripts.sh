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

  # Keep default-root TLS coverage in this existing whole-repository repair.
  # The focused TLS script separately exercises an explicit certificate target.
  local tls_root="${CERTS_DIR}/testcase/live/demo" tls_name tls_mode
  mkdir -p "$tls_root" || { fail "create default-root TLS fixture"; return; }
  if ! {
    printf 'dummy-key' >"${tls_root}/privkey.pem" &&
      printf 'client-key' >"${tls_root}/client.key" &&
      printf 'pkcs12-bytes' >"${tls_root}/client.p12" &&
      printf 'pkcs12-bytes-alt' >"${tls_root}/CLIENT.PFX" &&
      chmod 600 "${tls_root}/privkey.pem" "${tls_root}/client.p12" &&
      chmod 640 "${tls_root}/client.key" "${tls_root}/CLIENT.PFX"
  }; then
    fail "prepare default-root TLS fixture"
    return
  fi

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

  # shellcheck source=tests/fix_permissions_tls.d/get_mode.sh
  source "${ROOT_DIR}/tests/fix_permissions_tls.d/get_mode.sh" || { fail "load portable TLS mode helper"; return; }
  for tls_name in privkey.pem client.key client.p12 CLIENT.PFX; do
    tls_mode="$(get_mode "${tls_root}/${tls_name}")" || { fail "read ${tls_name} permissions"; return; }
    assertEquals "default-root repair must tighten ${tls_name} to 0600" 600 "$tls_mode"
  done
}
