#!/usr/bin/env bash

function integration_cli_tcp_port_is_listening() {
  local port="${1:-}"
  local checked=false

  if command -v lsof >/dev/null 2>&1; then
    checked=true
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi

  if command -v ss >/dev/null 2>&1; then
    checked=true
    ss -lnt 2>/dev/null | awk -v p=":$port" '
      $1 == "LISTEN" && ($4 ~ (p "$") || $4 ~ (p "[^0-9]")) { found = 1; exit }
      END { exit found ? 0 : 1 }
    ' && return 0
  fi

  if command -v netstat >/dev/null 2>&1; then
    checked=true
    netstat -an 2>/dev/null | grep -E "[\\.:]${port}([^0-9]|[[:space:]]).*LISTEN" >/dev/null 2>&1 && return 0
  fi

  if [ "$checked" = true ]; then
    return 1
  fi

  return 2
}

function integration_cli_find_free_tcp_port() {
  local port=17000
  local status=0
  while [ "$port" -le 17999 ]; do
    integration_cli_tcp_port_is_listening "$port"
    status=$?

    if [ "$status" -eq 1 ]; then
      printf '%s\n' "$port"
      return 0
    fi
    if [ "$status" -eq 2 ]; then
      return 2
    fi
    port=$((port + 1))
  done

  echo "[Error] Unable to find a free TCP port for integration test." >&2
  return 1
}

test_add_backend_fails_when_tcp_port_in_use() {
  local listen_port listen_status
  listen_port="$(integration_cli_find_free_tcp_port)"
  listen_status=$?
  if [ "$listen_status" -eq 2 ]; then
    startSkipping
    assertTrue "skip duplicate tcp add-backend check when no host TCP probe tool is available" 0
    endSkipping
    return 0
  fi
  [ "$listen_status" -eq 0 ] || return "$listen_status"

  run_dockistrate add-backend tcp-port.test nginx:alpine 8000 tcp --listen "$listen_port" >/dev/null
  assertEquals "seed tcp add-backend" 0 $?

  local output
  output="$(run_dockistrate add-backend tcp-port-conflict.test nginx:alpine 8001 tcp --listen "$listen_port")"
  local status=$?
  assertTrue "duplicate tcp add-backend should fail" "[ $status -ne 0 ]"
  assertStringContains "tcp port conflict error" "TCP port ${listen_port} is already in use" "$output"
}
