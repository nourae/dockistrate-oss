#!/usr/bin/env bash

test_stream_acl_allow_policy_emits_explicit_denies() {
  run_dockistrate add-backend stream.allow.test nginx:alpine 9100 tcp >/dev/null
  assertEquals "add-backend tcp" 0 $?

  run_dockistrate set-acl-policy allow >/dev/null
  assertEquals "set-acl-policy allow" 0 $?

  run_dockistrate add-acl stream.allow.test l7 deny 203.0.113.7 >/dev/null
  assertEquals "add-acl deny" 0 $?

  assertFileContainsSubstring 'include /etc/nginx/dockistrate/stream_conf/security_ip/stream.allow.test.inc;' "${CONFIG_DIR}/nginx_conf/stream_conf/streams.conf"
  assertFileContainsSubstring 'deny 203.0.113.7;' "${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/stream.allow.test.inc"
  assertFalse "deny all should not render for allow policy" "grep -q 'deny all;' \"${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/stream.allow.test.inc\""
}

test_stream_acl_explicit_denies_precede_allow_all() {
  run_dockistrate add-backend stream.order.test nginx:alpine 9200 tcp >/dev/null
  assertEquals "add-backend tcp" 0 $?

  run_dockistrate add-acl stream.order.test l7 allow 0.0.0.0/0 >/dev/null
  assertEquals "add-acl allow all" 0 $?

  run_dockistrate add-acl stream.order.test l7 deny 203.0.113.8 >/dev/null
  assertEquals "add-acl deny" 0 $?

  local include_file="${CONFIG_DIR}/nginx_conf/stream_conf/security_ip/stream.order.test.inc"
  local deny_line allow_all_line
  deny_line="$(awk '/deny 203[.]0[.]113[.]8;/{ print NR; exit }' "$include_file")"
  allow_all_line="$(awk '/allow all;/{ print NR; exit }' "$include_file")"
  [ -n "$deny_line" ] || deny_line=0
  [ -n "$allow_all_line" ] || allow_all_line=0

  assertFileContainsSubstring 'deny 203.0.113.8;' "$include_file"
  assertFileContainsSubstring 'allow all;' "$include_file"
  assertTrue "explicit stream deny should render before allow all" \
    "[ \"$deny_line\" -gt 0 ] && [ \"$allow_all_line\" -gt 0 ] && [ \"$deny_line\" -lt \"$allow_all_line\" ]"
}
