#!/usr/bin/env bash

test_nginx_directives_stream_render_and_precedence() {
  local output
  output="$(run_dockistrate add-backend stream-precedence.test nginx:alpine 9000 tcp)"
  assertEquals "add-backend tcp" 0 $?

  output="$(run_dockistrate set-nginx-directive stream-global proxy_connect_timeout 9s)"
  assertEquals "set stream-global directive" 0 $?

  output="$(run_dockistrate set-nginx-directive stream-backend stream-precedence.test proxy_connect_timeout 15s)"
  assertEquals "set stream-backend directive" 0 $?

  output="$(run_dockistrate set-nginx-directive stream-port stream-precedence.test 9000 proxy_connect_timeout 21s)"
  assertEquals "set stream-port directive" 0 $?

  local stream_global_include="${CONFIG_DIR}/nginx_conf/stream_conf/nginx_directives_stream_global.inc"
  local stream_conf="${CONFIG_DIR}/nginx_conf/stream_conf/streams.conf"

  output="$(run_dockistrate set-nginx-directive-raw stream-global log_format 'streamfmt $remote_addr $protocol')"
  assertEquals "set stream-global raw log_format directive" 0 $?

  assertFileContainsSubstring 'proxy_connect_timeout 9s;' "$stream_global_include"
  assertFileContainsSubstring 'log_format streamfmt $remote_addr $protocol;' "$stream_global_include"
  assertFileContainsSubstring 'proxy_connect_timeout 21s;' "$stream_conf"
  if grep -Fq 'log_format streamfmt $remote_addr $protocol;' "$stream_conf"; then
    fail "Expected stream-global log_format to render only at stream context, not inside stream server blocks"
  fi

  output="$(run_dockistrate remove-nginx-directive stream-port stream-precedence.test 9000 proxy_connect_timeout)"
  assertEquals "remove stream-port directive" 0 $?

  assertFileContainsSubstring 'proxy_connect_timeout 15s;' "$stream_conf"
  if grep -Fq 'proxy_connect_timeout 21s;' "$stream_conf"; then
    fail "Expected stream-port override (21s) to be removed from rendered stream server block"
  fi

  output="$(run_dockistrate remove-nginx-directive stream-backend stream-precedence.test proxy_connect_timeout)"
  assertEquals "remove stream-backend directive" 0 $?

  if grep -Fq 'proxy_connect_timeout 15s;' "$stream_conf"; then
    fail "Expected stream server block to stop rendering proxy_connect_timeout when only stream-global value remains"
  fi
}
