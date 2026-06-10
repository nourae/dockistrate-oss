#!/usr/bin/env bash

test_control_server_tokens_creates_conf_dir_when_missing() {
  local output status=0
  if output=$(cd "$ROOT_DIR" && SKIP_DOCKER_CHECKS=true ./dockistrate.sh control-server-tokens off 2>&1); then
    status=0
  else
    status=$?
  fi

  if [ "$status" -ne 0 ]; then
    printf 'control-server-tokens off should succeed, got exit %s\n%s\n' "$status" "$output" >&2
    exit 1
  fi
  if [ ! -f "$CONFIG_DIR/nginx_directives.csv" ]; then
    echo "[Error] directive state file should exist" >&2
    exit 1
  fi
  if ! grep -q '^global,,,,managed,server_tokens,off$' "$CONFIG_DIR/nginx_directives.csv"; then
    echo "[Error] managed server_tokens row should be persisted" >&2
    exit 1
  fi
  if [ -f "$CONF_D_DIR/server_tokens.conf" ]; then
    echo "[Error] legacy server_tokens.conf should not exist" >&2
    exit 1
  fi

  local show_output
  show_output="$(cd "$ROOT_DIR" && SKIP_DOCKER_CHECKS=true ./dockistrate.sh show-server-tokens 2>/dev/null)"
  if [ "$show_output" != "off" ]; then
    printf "show-server-tokens should read migrated directive state: expected 'off', got '%s'\n" "$show_output" >&2
    exit 1
  fi

  printf '%s\n' "$output"
}
