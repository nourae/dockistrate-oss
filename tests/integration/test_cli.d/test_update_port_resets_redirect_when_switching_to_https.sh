#!/usr/bin/env bash

test_update_port_resets_redirect_when_switching_to_https() {
  run_dockistrate add-backend redirect-switch.test nginx:alpine 8500 http >/dev/null
  assertEquals "seed add-backend" 0 $?

  run_dockistrate set-port-redirect redirect-switch.test 80 on 301 >/dev/null
  assertEquals "enable redirect" 0 $?

  run_dockistrate add-cert redirect-switch.test 443 selfsigned >/dev/null
  assertEquals "seed owned certificate" 0 $?

  local update_output
  # add-cert also establishes its HTTPS listener on 443. Convert the existing
  # redirecting HTTP listener to a separate HTTPS port to exercise its reset.
  update_output="$(run_dockistrate update-port redirect-switch.test 80 --nginx-port 8443 --protocol https --cert redirect-switch.test/selfsigned-443)"
  assertEquals "update-port https" 0 $?
  assertStringContains "update output" "Updated port mapping" "$update_output"

  assertFileContains "port,redirect-switch.test,,,,,8443,8500,https,redirect-switch.test/selfsigned-443,no,off," "${CONFIG_DIR}/backend_ports.csv"

  local conf
  conf="$(cat "${CONFIG_DIR}/nginx_conf/conf.d/backends.conf")"
  if grep -Fq "return 301 https://\$host\$request_uri;" <<<"$conf"; then
    fail "HTTPS listener should not include redirect block after protocol change"
  fi
}
