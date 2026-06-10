#!/usr/bin/env bash

test_uninstall_all_default_scope_removes_backend_residue() {
  run_dockistrate add-backend residue.test nginx:alpine 8181 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  run_dockistrate add-host-alias www.residue.test residue.test >/dev/null
  assertEquals "seed add-host-alias" 0 $?

  run_dockistrate add-dedicated-host app.residue.test residue.test no no no no no >/dev/null
  assertEquals "seed add-dedicated-host" 0 $?

  assertTrue "backend_ports.csv should exist before uninstall" "[ -f '${CONFIG_DIR}/backend_ports.csv' ]"
  assertTrue "backend_aliases.csv should exist before uninstall" "[ -f '${CONFIG_DIR}/backend_aliases.csv' ]"
  assertTrue "dedicated_host_inheritance.csv should exist before uninstall" "[ -f '${CONFIG_DIR}/dedicated_host_inheritance.csv' ]"
  assertTrue "backends.conf should exist before uninstall" "[ -f '${CONFIG_DIR}/nginx_conf/conf.d/backends.conf' ]"
  local path_header_dir="${CONFIG_DIR}/nginx_conf/conf.d/path_headers"
  local security_ip_dir="${CONFIG_DIR}/nginx_conf/conf.d/security_ip"
  local security_ip_stream_dir="${CONFIG_DIR}/nginx_conf/stream_conf/security_ip"
  mkdir -p "${path_header_dir}" "${security_ip_dir}" "${security_ip_stream_dir}"
  touch "${path_header_dir}/residue.inc" "${security_ip_dir}/residue.inc" "${security_ip_stream_dir}/residue.inc"
  assertTrue "path header dir should exist before uninstall" "[ -d '${path_header_dir}' ]"
  assertTrue "security ip dir should exist before uninstall" "[ -d '${security_ip_dir}' ]"
  assertTrue "security ip stream dir should exist before uninstall" "[ -d '${security_ip_stream_dir}' ]"

  local output
  output="$(run_dockistrate_with_interactive_yes uninstall-all)"
  assertEquals "uninstall-all default scope should succeed" 0 $?
  assertStringContains "default scope completion message" "Backend uninstall complete" "$output"

  assertTrue "backend_ports.csv should be removed" "[ ! -f '${CONFIG_DIR}/backend_ports.csv' ]"
  assertTrue "backend_aliases.csv should be removed" "[ ! -f '${CONFIG_DIR}/backend_aliases.csv' ]"
  assertTrue "dedicated_host_inheritance.csv should be removed" "[ ! -f '${CONFIG_DIR}/dedicated_host_inheritance.csv' ]"
  assertTrue "generated nginx config should be removed" "[ ! -d '${CONFIG_DIR}/nginx_conf' ]"
  assertTrue "path header dir should be removed" "[ ! -d '${path_header_dir}' ]"
  assertTrue "security ip dir should be removed" "[ ! -d '${security_ip_dir}' ]"
  assertTrue "security ip stream dir should be removed" "[ ! -d '${security_ip_stream_dir}' ]"
  assertTrue "global settings should remain for backend scope" "[ -f '${CONFIG_DIR}/global_settings.csv' ]"
  assertTrue "certs dir should be removed" "[ ! -d '${CERTS_DIR}' ]"
}

test_uninstall_all_scope_config_removes_config_keeps_logs_and_backups() {
  run_dockistrate add-backend config-scope.test nginx:alpine 8282 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  local output
  output="$(run_dockistrate_with_interactive_yes uninstall-all --scope config)"
  assertEquals "uninstall-all config scope should succeed" 0 $?
  assertStringContains "config scope completion message" "Config uninstall complete" "$output"

  assertTrue "config directory should be removed" "[ ! -d '${CONFIG_DIR}' ]"
  assertTrue "certs dir should be removed" "[ ! -d '${CERTS_DIR}' ]"
  assertTrue "logs directory should remain" "[ -d '${LOG_DIR}' ]"
  assertTrue "backups directory should remain" "[ -d '${BACKUP_DIR}' ]"
}

test_uninstall_all_scope_all_removes_runtime_dirs_keeps_logs_and_backups() {
  local acme_dir="${STATE_DIR}/acme-webroot"

  run_dockistrate add-backend all-scope.test nginx:alpine 8383 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  mkdir -p "${TMP_DIR}" "${CAPTURE_DIR}" "${acme_dir}"
  touch "${TMP_DIR}/tmp.txt" "${CAPTURE_DIR}/cap.txt" "${acme_dir}/acme.txt"

  local output
  output="$(run_dockistrate_with_interactive_yes uninstall-all --scope all)"
  assertEquals "uninstall-all all scope should succeed" 0 $?
  assertStringContains "all scope completion message" "Full runtime uninstall complete" "$output"

  assertTrue "config directory should be removed" "[ ! -d '${CONFIG_DIR}' ]"
  assertTrue "certs dir should be removed" "[ ! -d '${CERTS_DIR}' ]"
  assertTrue "tmp dir should be removed" "[ ! -d '${TMP_DIR}' ]"
  assertTrue "capture dir should be removed" "[ ! -d '${CAPTURE_DIR}' ]"
  assertTrue "acme dir should be removed" "[ ! -d '${acme_dir}' ]"
  assertTrue "logs directory should remain" "[ -d '${LOG_DIR}' ]"
  assertTrue "backups directory should remain" "[ -d '${BACKUP_DIR}' ]"
}

test_uninstall_all_rejects_invalid_scope() {
  local output
  output="$(run_dockistrate uninstall-all --scope nope)"
  local status=$?

  assertTrue "invalid scope should fail" "[ $status -ne 0 ]"
  assertStringContains "invalid scope error" "Invalid scope" "$output"
}

test_uninstall_all_preserves_unrelated_backend_named_containers() {
  local fake_bin rm_log rm_raw_log output status ps_names
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-uninstall.XXXXXX")"
  rm_log="${fake_bin}/docker-rm.log"
  rm_raw_log="${fake_bin}/docker-rm-raw.log"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    cat <<EOF
if [ "\${1:-}" = "rm" ]; then
  shift || true
  printf '%s\n' "\$*" >>"${rm_raw_log}"
  for arg in "\$@"; do
    case "\$arg" in
      -*) ;;
      *) printf '%s\n' "\$arg" >>"${rm_log}" ;;
    esac
  done
  exit 0
fi
exec bash "${ROOT_DIR}/tests/mocks/docker" "\$@"
EOF
  } >"${fake_bin}/docker"
  chmod +x "${fake_bin}/docker"

  ps_names=$'backend-orphan-1\nrandom-container\nbackend-orphan-2'
  output="$(INTEGRATION_RUNTIME_PATH="${fake_bin}:${MOCK_BIN_DIR}:$PATH" DOCKER_MOCK_PS_NAMES="$ps_names" run_dockistrate_with_interactive_yes uninstall-all)"
  status=$?

  assertEquals "uninstall-all should succeed without claiming unrelated backend-named containers" 0 $status
  assertTrue "uninstall-all should not remove backend-orphan-1" "! grep -q '^backend-orphan-1$' '${rm_log}'"
  assertTrue "uninstall-all should not remove backend-orphan-2" "! grep -q '^backend-orphan-2$' '${rm_log}'"
  assertTrue "uninstall-all should not remove non-backend container" "! grep -q '^random-container$' '${rm_log}'"
  assertTrue "uninstall-all output should not report unrelated backend-orphan-1 removal" \
    "! printf '%s' \"$output\" | grep -Fq 'backend-orphan-1'"
  assertTrue "uninstall-all output should not report unrelated backend-orphan-2 removal" \
    "! printf '%s' \"$output\" | grep -Fq 'backend-orphan-2'"

  rm -rf "$fake_bin"
}

test_uninstall_all_removes_state_derived_backend_containers_only() {
  local fake_bin rm_log rm_raw_log output status ps_names managed_container runtime_mock_dir
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-uninstall.XXXXXX")"
  rm_log="${fake_bin}/docker-rm.log"
  rm_raw_log="${fake_bin}/docker-rm-raw.log"
  managed_container="backend-managed.test"
  runtime_mock_dir="${STATE_DIR}/tmp/.docker_mock"

  run_dockistrate add-backend managed.test nginx:alpine 8484 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  mkdir -p "${runtime_mock_dir}"
  cat >"${runtime_mock_dir}/${managed_container}.meta" <<'EOF_META'
status=running
labels=
mounts=
EOF_META

  {
    printf '%s\n' '#!/usr/bin/env bash'
    cat <<EOF
if [ "\${1:-}" = "rm" ]; then
  shift || true
  printf '%s\n' "\$*" >>"${rm_raw_log}"
  for arg in "\$@"; do
    case "\$arg" in
      -*) ;;
      *) printf '%s\n' "\$arg" >>"${rm_log}" ;;
    esac
  done
  exit 0
fi
exec bash "${ROOT_DIR}/tests/mocks/docker" "\$@"
EOF
  } >"${fake_bin}/docker"
  chmod +x "${fake_bin}/docker"

  ps_names="${managed_container}"$'\n''backend-orphan-1'
  output="$(INTEGRATION_RUNTIME_PATH="${fake_bin}:${MOCK_BIN_DIR}:$PATH" DOCKER_MOCK_PS_NAMES="$ps_names" run_dockistrate_with_interactive_yes uninstall-all)"
  status=$?

  assertEquals "uninstall-all should succeed for state-derived backend removal" 0 $status
  assertStringContains "uninstall-all should report managed backend removal" "${managed_container}" "$output"
  assertTrue "uninstall-all should remove managed backend container" "grep -q '^${managed_container}$' '${rm_log}'"
  assertTrue "uninstall-all should preserve unrelated backend-named container" "! grep -q '^backend-orphan-1$' '${rm_log}'"
  assertTrue "state-derived backend rm should include -f -v" \
    "grep -Eq '^-f -v ${managed_container}$' '${rm_raw_log}'"

  rm -rf "$fake_bin"
}
