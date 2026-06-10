#!/usr/bin/env bash

test_update_port_resets_redirect_when_switching_to_https() {
  run_dockistrate add-backend redirect-switch.test nginx:alpine 8500 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  run_dockistrate set-port-redirect redirect-switch.test 80 on 301 >/dev/null
  assertEquals "enable redirect" 0 $?

  mkdir -p "${CERTS_DIR}/custom/live/redirect-switch.test_443"

  local update_output
  update_output="$(run_dockistrate update-port redirect-switch.test 80 --nginx-port 443 --protocol https --cert certs/custom/live/redirect-switch.test_443)"
  assertEquals "update-port https" 0 $?
  assertStringContains "update output" "Updated port mapping" "$update_output"

  assertFileContains "port,redirect-switch.test,,,,,443,8500,https,custom/live/redirect-switch.test_443,no,off," "${CONFIG_DIR}/backend_ports.csv"

  local conf
  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  if grep -Fq "return 301 https://\$host\$request_uri;" <<<"$conf"; then
    fail "HTTPS listener should not include redirect block after protocol change"
  fi
}
