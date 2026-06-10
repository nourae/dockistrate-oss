#!/usr/bin/env bash

test_update_port_nginx_directive_reconciliation() {
  local directives_file="${CONFIG_DIR}/nginx_directives.csv"
  local output status

  run_dockistrate add-backend remap-http.test nginx:alpine 9301 http >/dev/null
  assertEquals "seed http remap backend" 0 $?
  run_dockistrate add-dedicated-host admin.remap-http.test remap-http.test >/dev/null
  assertEquals "seed dedicated host for http remap" 0 $?
  run_dockistrate set-nginx-directive port remap-http.test 80 proxy_read_timeout 30s >/dev/null
  assertEquals "seed backend http port directive" 0 $?
  run_dockistrate set-nginx-directive port admin.remap-http.test 80 send_timeout 31s >/dev/null
  assertEquals "seed dedicated host http port directive" 0 $?

  output="$(run_dockistrate update-port remap-http.test 80 --nginx-port 81 --protocol http)"
  assertEquals "update-port http remap" 0 $?
  assertStringContains "update-port http remap output" "Updated port mapping for remap-http.test on 81." "$output"

  if ! grep -q '^port,remap-http.test,81,,managed,proxy_read_timeout,30s$' "$directives_file"; then
    fail "Expected backend http port directive to move from :80 to :81"
  fi
  if grep -q '^port,remap-http.test,80,' "$directives_file"; then
    fail "Expected no backend http port directive rows to remain on :80 after remap"
  fi
  if ! grep -q '^port,admin.remap-http.test,81,,managed,send_timeout,31s$' "$directives_file"; then
    fail "Expected dedicated-host http port directive to move from :80 to :81"
  fi
  if grep -q '^port,admin.remap-http.test,80,' "$directives_file"; then
    fail "Expected no dedicated-host http port directive rows to remain on :80 after remap"
  fi

  run_dockistrate add-backend switch-http-tcp.test nginx:alpine 9302 http >/dev/null
  assertEquals "seed http->tcp backend" 0 $?
  run_dockistrate add-dedicated-host admin.switch-http-tcp.test switch-http-tcp.test >/dev/null
  assertEquals "seed dedicated host for http->tcp switch" 0 $?
  run_dockistrate set-nginx-directive port switch-http-tcp.test 80 proxy_send_timeout 32s >/dev/null
  assertEquals "seed backend directive for http->tcp switch" 0 $?
  run_dockistrate set-nginx-directive port admin.switch-http-tcp.test 80 proxy_connect_timeout 33s >/dev/null
  assertEquals "seed dedicated-host directive for http->tcp switch" 0 $?

  output="$(run_dockistrate update-port switch-http-tcp.test 80 --protocol tcp)"
  assertEquals "update-port http->tcp switch" 0 $?
  assertStringContains "update-port http->tcp output" "Updated port mapping for switch-http-tcp.test on 80." "$output"

  if grep -q '^port,switch-http-tcp.test,80,' "$directives_file"; then
    fail "Expected backend http port directive rows to be purged after switching protocol to tcp"
  fi
  if grep -q '^port,admin.switch-http-tcp.test,80,' "$directives_file"; then
    fail "Expected dedicated-host http port directive rows to be purged after switching protocol to tcp"
  fi

  run_dockistrate add-backend remap-stream.test nginx:alpine 9303 tcp >/dev/null
  assertEquals "seed tcp remap backend" 0 $?
  run_dockistrate set-nginx-directive stream-port remap-stream.test 9303 proxy_timeout 41s >/dev/null
  assertEquals "seed stream-port directive for tcp remap" 0 $?

  output="$(run_dockistrate update-port remap-stream.test 9303 --nginx-port 9304 --protocol tcp)"
  assertEquals "update-port tcp remap" 0 $?
  assertStringContains "update-port tcp remap output" "Updated port mapping for remap-stream.test on 9304." "$output"

  if ! grep -q '^stream-port,remap-stream.test,9304,,managed,proxy_timeout,41s$' "$directives_file"; then
    fail "Expected stream-port directive to move from :9303 to :9304"
  fi
  if grep -q '^stream-port,remap-stream.test,9303,' "$directives_file"; then
    fail "Expected no stream-port directive rows to remain on :9303 after tcp remap"
  fi

  run_dockistrate add-backend switch-tcp-http.test nginx:alpine 9305 tcp >/dev/null
  assertEquals "seed tcp->http backend" 0 $?
  run_dockistrate set-nginx-directive stream-port switch-tcp-http.test 9305 proxy_connect_timeout 42s >/dev/null
  assertEquals "seed stream-port directive for tcp->http switch" 0 $?

  output="$(run_dockistrate update-port switch-tcp-http.test 9305 --protocol http)"
  assertEquals "update-port tcp->http switch" 0 $?
  assertStringContains "update-port tcp->http output" "Updated port mapping for switch-tcp-http.test on 9305." "$output"

  if grep -q '^stream-port,switch-tcp-http.test,9305,' "$directives_file"; then
    fail "Expected stream-port directive rows to be purged after switching protocol to http"
  fi

  run_dockistrate add-backend rollback-update-port.test nginx:alpine 9306 http >/dev/null
  assertEquals "seed rollback backend" 0 $?
  run_dockistrate set-nginx-directive port rollback-update-port.test 80 proxy_read_timeout 50s >/dev/null
  assertEquals "seed rollback directive" 0 $?

  printf '%s\n' 'global,,,,managed,not_in_catalog,1' >>"$directives_file"

  local before_ports before_directives after_ports after_directives
  before_ports="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  before_directives="$(cat "$directives_file")"

  output="$(run_dockistrate update-port rollback-update-port.test 80 --nginx-port 81 --protocol http)"
  status=$?
  assertTrue "update-port should fail when render validation fails after mutation" "[ $status -ne 0 ]"
  assertStringContains "update-port rollback output should mention rollback" "Rolled back" "$output"

  after_ports="$(cat "${CONFIG_DIR}/backend_ports.csv")"
  after_directives="$(cat "$directives_file")"
  if [ "$before_ports" != "$after_ports" ]; then
    fail "Expected backend_ports.csv to roll back to pre-update-port content on failure"
  fi
  if [ "$before_directives" != "$after_directives" ]; then
    fail "Expected nginx_directives.csv to roll back to pre-update-port content on failure"
  fi
}
