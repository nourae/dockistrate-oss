#!/usr/bin/env bash

function _security_identity_run() {
  local output status
  output="$(run_dockistrate "$@")"; status=$?
  assertEquals "$* succeeds: $output" 0 "$status"
  return "$status"
}

function _security_identity_rule_lines() {
  local hostname="$1"
  grep -F "if (\$dockistrate_security_identity = $hostname)" \
    "$CONFIG_DIR/nginx_conf/conf.d/security_rules.inc" || true
}

function test_security_rules_apply_to_aliases_and_inheriting_hosts_http_https() {
  local primary="rule-primary.test" normal="normal.rule-primary.test"
  local split="split.rule-primary.test" inherited="inherited.rule-primary.test"
  local independent="independent.rule-primary.test" hostname port block default_identity rules
  local blocks proxies includes identity_line include_line
  _security_identity_run add-backend "$primary" nginx:alpine 18180 https || return
  _security_identity_run add-port "$primary" 8080 18180 http none || return
  _security_identity_run add-host-alias "$normal" "$primary" || return
  _security_identity_run add-host-alias "$split" "$primary" || return
  _security_identity_run add-dedicated-host "$inherited" "$primary" || return
  _security_identity_run add-dedicated-host "$independent" "$primary" yes yes no yes yes || return
  _security_identity_run add-acl "$split" both deny 192.0.2.20 || return
  _security_identity_run add-security-rule "$primary" 1 header X-Single equals pass --code 451 || return
  _security_identity_run add-security-rule "$primary" 2 header X-Or-A equals pass header X-Or-B equals pass --mode or --code 452 || return
  _security_identity_run add-security-rule "$primary" 2 header X-And-A equals pass header X-And-B equals pass --mode and --code 453 || return
  _security_identity_run add-path-option "$primary" 443 /private --ws yes || return
  _security_identity_run add-path-option "$primary" 8080 /private --ws yes || return

  for port in 8080 443; do
    for hostname in "$primary" "$normal" "$split" "$inherited" "$independent"; do
      # Reuse the serving-block extractor from the alias ACL regression; it
      # matches both grouped aliases and independent server blocks.
      block="$(_alias_acl_server_block "$hostname" "$port")"
      blocks="$(printf '%s\n' "$block" | grep -c '^server {' || true)"
      assertEquals "$hostname:$port has exactly one serving block" 1 "$blocks"
      default_identity="$hostname"
      [ "$hostname" != "$normal" ] || default_identity="$primary"
      assertStringContains "$hostname:$port sets its trusted default identity" \
        "set \$dockistrate_security_identity \"${default_identity}\";" "$block"
      identity_line="$(printf '%s\n' "$block" | awk '/set \$dockistrate_security_identity / { print NR; exit }')"
      include_line="$(printf '%s\n' "$block" | awk '/include .*\/security_rules.inc;/ { print NR; exit }')"
      assertTrue "$hostname:$port establishes identity before request rules" \
        "[ '${identity_line:-0}' -gt 0 ] && [ '${include_line:-0}' -gt '${identity_line:-0}' ]"
      proxies="$(printf '%s\n' "$block" | grep -c 'proxy_pass ' || true)"
      includes="$(printf '%s\n' "$block" | grep -c '/security_rules.inc;' || true)"
      assertEquals "$hostname:$port protects every backend proxy location" "$proxies" "$includes"
      assertEquals "$hostname:$port includes both default and inherited private paths" 2 "$proxies"
      assertStringContains "$hostname:$port preserves upstream Host" 'proxy_set_header Host $host;' "$block"
      assertFalse "$hostname:$port must not rewrite the request Host variable" \
        "printf '%s\n' \"\$block\" | grep -Fq 'set \$host '"
    done
    block="$(_alias_acl_server_block "$normal" "$port")"
    assertStringContains 'grouped aliases select only a configured recipient identity' \
      "if (\$host = ${normal}) { set \$dockistrate_security_identity \"${normal}\"; }" "$block"
    assertFalse 'split alias must not remain in the primary identity whitelist' \
      "printf '%s\n' \"\$block\" | grep -Fq 'set \$dockistrate_security_identity \"${split}\";'"
    block="$(_alias_acl_server_block "$split" "$port")"
    assertStringContains 'split alias retains its own ACL include' "/security_ip/${split}.inc;" "$block"
  done

  for hostname in "$primary" "$normal" "$split" "$inherited"; do
    rules="$(_security_identity_rule_lines "$hostname")"
    assertEquals "$hostname receives all three backend rule modes" 3 "$(printf '%s\n' "$rules" | grep -c 'return ' || true)"
    assertStringContains "$hostname receives the single predicate" '$http_x_single' "$rules"
    assertStringContains "$hostname receives the OR predicates" '$http_x_or_b' "$rules"
    assertStringContains "$hostname receives the AND predicates" '$http_x_and_b' "$rules"
    for port in 451 452 453; do
      assertStringContains "$hostname preserves explicit rule status $port" "return ${port};" "$rules"
    done
  done
  assertEquals 'inheritance=no excludes all inherited request rules' '' "$(_security_identity_rule_lines "$independent")"
}

function test_security_rule_inheritance_changes_and_render_failure_preserve_policy() {
  local primary="rule-transition.test" dedicated="dedicated.rule-transition.test"
  local before_config before_rules output status inheritance_file
  _security_identity_run add-backend "$primary" nginx:alpine 18180 http || return
  _security_identity_run add-dedicated-host "$dedicated" "$primary" yes yes no yes yes || return
  _security_identity_run add-security-rule "$primary" 1 header X-Guard equals pass --code 451 || return
  assertEquals 'initially disabled inheritance has no backend rule' '' "$(_security_identity_rule_lines "$dedicated")"
  _security_identity_run set-dedicated-host-inherit "$dedicated" security_rules yes || return
  assertStringContains 'enabling inheritance activates the existing backend rule' '$http_x_guard' "$(_security_identity_rule_lines "$dedicated")"

  before_config="$(cat "$CONFIG_DIR/nginx_conf/conf.d/backends.conf")"
  before_rules="$(cat "$CONFIG_DIR/nginx_conf/conf.d/security_rules.inc")"
  inheritance_file="$STATE_DIR/domains/$dedicated/runtime/applied/inheritance.csv"
  cp "$inheritance_file" "$TMP_DIR/security-inheritance.saved"
  # Deliberately corrupt persisted input to exercise the render boundary.
  if ! integration_domain_csv_set "$inheritance_file" security_rules invalid; then
    fail "Unable to seed invalid security-rule inheritance"
    return 1
  fi
  output="$(run_dockistrate update-nginx-config 2>&1)"; status=$?
  assertNotEquals 'malformed inheritance must fail closed' 0 "$status"
  assertStringContains 'malformed inheritance produces an actionable error' 'inherit' "$output"
  assertEquals 'failed rendering preserves serving configuration' "$before_config" "$(cat "$CONFIG_DIR/nginx_conf/conf.d/backends.conf")"
  assertEquals 'failed rendering preserves effective request rules' "$before_rules" "$(cat "$CONFIG_DIR/nginx_conf/conf.d/security_rules.inc")"
  mv "$TMP_DIR/security-inheritance.saved" "$inheritance_file"

  # A valid-shaped rule whose backend disappeared must also preserve the
  # last complete serving policy when regeneration cannot resolve its identity.
  local identity_source="$STATE_DIR/domains/$dedicated/runtime/applied/domain.csv"
  cp "$identity_source" "$TMP_DIR/security-rules.saved"
  if ! integration_domain_csv_set "$identity_source" target missing.rule-transition.test; then
    fail "Unable to seed unresolved dedicated-host target"
    return 1
  fi
  output="$(run_dockistrate update-nginx-config 2>&1)"; status=$?
  assertNotEquals 'enabled rules with missing identities must fail closed' 0 "$status"
  assertStringContains 'unresolved identity is reported' 'target must be a configured primary backend' "$output"
  assertEquals 'unknown identity preserves serving configuration' "$before_config" "$(cat "$CONFIG_DIR/nginx_conf/conf.d/backends.conf")"
  assertEquals 'unknown identity preserves effective request rules' "$before_rules" "$(cat "$CONFIG_DIR/nginx_conf/conf.d/security_rules.inc")"
  mv "$TMP_DIR/security-rules.saved" "$identity_source"

  _security_identity_run set-dedicated-host-inherit "$dedicated" security_rules no || return
  assertEquals 'disabling inheritance removes the expanded backend rule' '' "$(_security_identity_rule_lines "$dedicated")"
}
