#!/usr/bin/env bash

test_https_cert_paths_are_normalized_relative_to_certs_dir() {
  local backend_cert_dir="${CERTS_DIR}/custom/live/abs-backend.test_4443"
  mkdir -p "$backend_cert_dir"
  printf 'CERT' >"${backend_cert_dir}/fullchain.pem"
  printf 'KEY' >"${backend_cert_dir}/privkey.pem"

  local output
  local add_backend_cmd=(
    add-backend abs-backend.test nginx:alpine 9443 https
    --listen 4443
    --cert "$backend_cert_dir"
  )
  output="$(run_dockistrate "${add_backend_cmd[@]}")"
  assertEquals "https add-backend should succeed" 0 $?

  assertFileContains "port,abs-backend.test,,,,,4443,9443,https,custom/live/abs-backend.test_4443,no,off," "${CONFIG_DIR}/backend_ports.csv"

  local conf
  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertStringContains "backend config should reference container cert path" \
    "/etc/letsencrypt/custom/live/abs-backend.test_4443" "$conf"

  run_dockistrate add-backend abs-port.test nginx:alpine 9555 http >/dev/null
  assertEquals "seed backend with http port" 0 $?

  local port_cert_dir="${CERTS_DIR}/custom/live/abs-port.test_4444"
  mkdir -p "$port_cert_dir"
  printf 'CERT' >"${port_cert_dir}/fullchain.pem"
  printf 'KEY' >"${port_cert_dir}/privkey.pem"

  local add_port_cmd=(
    add-port abs-port.test 4444 9555 https
    "$port_cert_dir" no
  )
  output="$(run_dockistrate "${add_port_cmd[@]}")"
  assertEquals "https add-port should succeed" 0 $?
  assertStringContains "https add-port output" "Added port mapping" "$output"

  assertFileContains "port,abs-port.test,,,,,4444,9555,https,custom/live/abs-port.test_4444,no,off," "${CONFIG_DIR}/backend_ports.csv"

  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertStringContains "port mapping should reference container cert path" \
    "/etc/letsencrypt/custom/live/abs-port.test_4444" "$conf"

  local abs_port_cert="${CERTS_DIR}/custom/live/abs-port.test_4444"
  local csv_path="${CONFIG_DIR}/backend_ports.csv"
  local tmp_csv="${csv_path}.tmp"
  sed "s@custom/live/abs-port.test_4444@${abs_port_cert}@" "$csv_path" >"$tmp_csv"

  if diff -q "$csv_path" "$tmp_csv" >/dev/null; then
    rm -f "$tmp_csv"
    fail "expected relative cert entry missing"
  fi

  mv "$tmp_csv" "$csv_path"

  output="$(run_dockistrate update-port abs-port.test 4444)"
  assertEquals "update-port should succeed" 0 $?
  assertStringContains "update output mentions success" "Updated port mapping for abs-port.test on 4444" "$output"

  assertFileContains "port,abs-port.test,,,,,4444,9555,https,custom/live/abs-port.test_4444,no,off," "${CONFIG_DIR}/backend_ports.csv"
  if grep -q "${CERTS_DIR}" "${CONFIG_DIR}/backend_ports.csv"; then
    fail "backend_ports.csv should not store absolute certificate paths"
  fi

  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  assertStringContains "updated config should continue using container cert path" \
    "/etc/letsencrypt/custom/live/abs-port.test_4444" "$conf"
}
