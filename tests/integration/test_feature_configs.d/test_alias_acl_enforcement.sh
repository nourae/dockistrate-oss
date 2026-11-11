#!/usr/bin/env bash

function _alias_acl_run() {
  local output status
  output="$(run_dockistrate "$@")"; status=$?
  assertEquals "$* succeeds: $output" 0 "$status"
  return "$status"
}

# Select the actual server that accepts a hostname, including grouped aliases.
function _alias_acl_server_block() {
  local hostname="$1" port="$2"
  awk -v hostname="$hostname" -v port="$port" '
    /^server \{/ { block=""; matches_name=0; matches_port=0; in_server=1 }
    in_server {
      block=block $0 "\n"
      if ($1 == "server_name") {
        for (i=2; i<=NF; i++) {
          name=$i; sub(/;$/, "", name)
          if (name == hostname) matches_name=1
        }
      }
      if ($1 == "listen") {
        listener=$2; sub(/;$/, "", listener)
        if (listener == port) matches_port=1
      }
    }
    /^}/ && in_server {
      if (matches_name && matches_port) printf "%s", block
      in_server=0
    }
  ' "$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
}

function _alias_acl_assert_include() {
  local hostname="$1" port="$2" policy_domain="$3" block count
  block="$(_alias_acl_server_block "$hostname" "$port")"
  count="$(printf '%s\n' "$block" | grep -c '^server {' || true)"
  assertEquals "$hostname:$port has exactly one serving block" 1 "$count"
  assertStringContains "$hostname:$port must attach its effective ACL" \
    "/security_ip/${policy_domain}.inc;" "$block"
}

function test_alias_acl_http_https_preserves_primary_configuration() {
  local primary="acl-shared.test" alias="restricted.acl-shared.test"
  local normal="ordinary.acl-shared.test" dedicated="dedicated.acl-shared.test"
  local primary_block alias_block normal_block line port
  local acl_dir="$CONFIG_DIR/nginx_conf/conf.d/security_ip"

  _alias_acl_run add-backend "$primary" nginx:alpine 18180 https || return
  _alias_acl_run add-port "$primary" 8080 18180 http none || return
  _alias_acl_run set-backend-acl-policy "$primary" allow || return
  _alias_acl_run set-trusted-proxies 127.0.0.1/32 || return
  _alias_acl_run set-backend-client-ip-header "$primary" X-Client-IP || return
  _alias_acl_run add-backend-header "$primary" response X-Alias-Policy shared || return
  _alias_acl_run add-path-option "$primary" 443 /private --ws yes || return
  _alias_acl_run enable-backend-mtls "$primary" aliasClient || return
  _alias_acl_run add-host-alias "$alias" "$primary" || return
  _alias_acl_run add-host-alias "$normal" "$primary" || return
  _alias_acl_run add-dedicated-host "$dedicated" "$primary" || return
  _alias_acl_run add-acl "$primary" both deny 192.0.2.10 || return
  _alias_acl_run add-acl "$alias" both deny 192.0.2.20 || return

  for port in 8080 443; do
    _alias_acl_assert_include "$alias" "$port" "$alias"
    _alias_acl_assert_include "$primary" "$port" "$primary"
    _alias_acl_assert_include "$normal" "$port" "$primary"
    _alias_acl_assert_include "$dedicated" "$port" "$dedicated"
    alias_block="$(_alias_acl_server_block "$alias" "$port")"
    assertStringContains 'restricted alias has an independent server name' \
      "server_name ${alias};" "$alias_block"
    assertStringContains 'alias keeps the primary client-IP identity header' \
      'real_ip_header X-Client-IP;' "$alias_block"
    assertTrue 'real-IP directives precede the alias ACL include' \
      "printf '%s\n' \"\$alias_block\" | awk '/real_ip_header / { realip=NR } /include .*security_ip\// { acl=NR } END { exit !(realip > 0 && acl > realip) }'"
  done
  assertFileContainsSubstring 'deny 192.0.2.20;' "$acl_dir/$alias.inc"
  assertFileContainsSubstring 'deny 192.0.2.10;' "$acl_dir/$primary.inc"
  assertFileContainsSubstring 'deny 192.0.2.10;' "$acl_dir/$dedicated.inc"
  assertFalse 'alias-specific deny must not alter primary ACL rows' \
    "grep -Fq '192.0.2.20' '$acl_dir/$primary.inc'"
  assertFalse 'explicit alias rules replace, rather than append to, primary rules' \
    "grep -Fq '192.0.2.10' '$acl_dir/$alias.inc'"
  assertFalse 'alias without a policy override inherits primary allow policy' \
    "grep -Eq '= 0\) \{ return|deny all;' '$acl_dir/$alias.inc'"

  primary_block="$(_alias_acl_server_block "$primary" 443)"
  alias_block="$(_alias_acl_server_block "$alias" 443)"
  normal_block="$(_alias_acl_server_block "$normal" 443)"
  assertEquals 'unconfigured alias stays on the original primary server' "$primary_block" "$normal_block"
  assertStringContains 'restricted alias retains primary path routing' 'location /private {' "$alias_block"
  assertStringContains 'restricted alias retains primary mTLS enforcement' 'ssl_verify_client on;' "$alias_block"
  assertStringContains 'restricted alias retains the primary response-header identity' \
    "set \$dockistrate_backend_header_key \"${primary}\";" "$alias_block"
  assertStringContains 'restricted alias keeps backend response-header rendering' '/backend_headers.conf;' "$alias_block"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    assertStringContains 'restricted alias retains primary certificate, CA, CRL and header references' "$line" "$alias_block"
  done <<<"$(printf '%s\n' "$primary_block" | grep -E 'ssl_(certificate|certificate_key|client_certificate|crl) ')"
}

function test_alias_acl_rule_lifecycle_and_alias_removal() {
  local primary="acl-lifecycle.test" alias="restricted.acl-lifecycle.test"
  local db="$CONFIG_DIR/security_ip_rules.csv" acl_dir="$CONFIG_DIR/nginx_conf/conf.d/security_ip"
  local file
  _alias_acl_run add-backend "$primary" nginx:alpine 18180 http || return
  _alias_acl_run set-backend-acl-policy "$primary" allow || return
  _alias_acl_run add-acl "$primary" both deny 192.0.2.10 || return
  _alias_acl_run add-host-alias "$alias" "$primary" || return
  _alias_acl_run add-acl "$alias" both deny 192.0.2.20 || return
  _alias_acl_assert_include "$alias" 80 "$alias"

  _alias_acl_run disable-acl 2 || return
  _alias_acl_assert_include "$alias" 80 "$primary"
  _alias_acl_run enable-acl 2 || return
  _alias_acl_assert_include "$alias" 80 "$alias"
  _alias_acl_run remove-acl 2 || return
  _alias_acl_assert_include "$alias" 80 "$primary"
  assertFileContainsSubstring 'deny 192.0.2.10;' "$acl_dir/$primary.inc"

  _alias_acl_run add-acl "$alias" both deny 192.0.2.20 || return
  _alias_acl_run set-backend-acl-policy "$alias" deny || return
  _alias_acl_run set-backend-acl-status "$alias" 451 || return
  _alias_acl_run remove-host-alias "$alias" || return
  for file in "$db" "$CONFIG_DIR/backend_acl_policies.csv" "$CONFIG_DIR/backend_acl_statuses.csv"; do
    assertFalse 'removing an alias removes its ACL rows and overrides' \
      "grep -Fq '$alias,' '$file'"
  done
  assertFalse 'removing an alias removes its generated HTTP ACL include' "[ -e '$acl_dir/$alias.inc' ]"
  assertFalse 'removing an alias removes its generated stream ACL include' \
    "[ -e '$CONFIG_DIR/nginx_conf/stream_conf/security_ip/$alias.inc' ]"
  _alias_acl_run add-host-alias "$alias" "$primary" || return
  _alias_acl_assert_include "$alias" 80 "$primary"
  assertFileContainsSubstring 'deny 192.0.2.10;' "$acl_dir/$primary.inc"
}

function test_alias_acl_policy_and_status_overrides_without_own_rules() {
  local primary="acl-defaults.test" policy_alias="policy.acl-defaults.test"
  local status_alias="status.acl-defaults.test" acl_dir="$CONFIG_DIR/nginx_conf/conf.d/security_ip"
  _alias_acl_run add-backend "$primary" nginx:alpine 18180 http || return
  _alias_acl_run set-backend-acl-status "$primary" 451 || return
  _alias_acl_run add-acl "$primary" both allow 192.0.2.10 || return
  _alias_acl_run add-acl "$primary" both deny 192.0.2.20 || return
  _alias_acl_run add-host-alias "$policy_alias" "$primary" || return
  _alias_acl_run add-host-alias "$status_alias" "$primary" || return

  _alias_acl_run set-backend-acl-policy "$policy_alias" allow || return
  _alias_acl_assert_include "$policy_alias" 80 "$policy_alias"
  assertFileContainsSubstring 'return 451;' "$acl_dir/$policy_alias.inc"
  assertFileContainsSubstring '192.0.2.20' "$acl_dir/$policy_alias.inc"
  assertFalse 'allow override must not retain the primary default-deny guard' \
    "grep -Eq '= 0\) \{ return|deny all;' '$acl_dir/$policy_alias.inc'"

  _alias_acl_run set-backend-acl-status "$status_alias" 429 || return
  _alias_acl_assert_include "$status_alias" 80 "$status_alias"
  assertFileContainsSubstring '192.0.2.10' "$acl_dir/$status_alias.inc"
  assertFileContainsSubstring '192.0.2.20' "$acl_dir/$status_alias.inc"
  assertFileContainsSubstring '= 0) { return 429; }' "$acl_dir/$status_alias.inc"
  assertFileContainsSubstring '= 0) { return 451; }' "$acl_dir/$primary.inc"

  _alias_acl_run remove-backend-acl-policy "$policy_alias" || return
  _alias_acl_assert_include "$policy_alias" 80 "$primary"
  _alias_acl_run remove-backend-acl-status "$status_alias" || return
  _alias_acl_assert_include "$status_alias" 80 "$primary"
}

function test_alias_acl_readiness_failure_restores_shared_server() {
  local primary="acl-rollback.test" alias="restricted.acl-rollback.test"
  local output status before after docker_log="$STATE_DIR/alias_acl_rollback.log"
  SKIP_DOCKER_CHECKS=false _alias_acl_run add-backend "$primary" nginx:alpine 18180 http || return
  _alias_acl_run set-backend-acl-policy "$primary" allow || return
  _alias_acl_run add-host-alias "$alias" "$primary" || return
  DOCKER_MOCK_PS_NAMES='' SKIP_DOCKER_CHECKS=false _alias_acl_run start-nginx || return
  before="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"

  output="$(DOCKER_MOCK_EXEC_FAIL=true DOCKISTRATE_SECURITY_NGINX_READY_ATTEMPTS=1 \
    DOCKER_MOCK_PORT_BINDINGS='80/tcp -> 0.0.0.0:80' DOCKER_MOCK_LOG_FILE="$docker_log" \
    SKIP_DOCKER_CHECKS=false run_dockistrate add-acl "$alias" both deny 192.0.2.20)"; status=$?
  assertNotEquals 'alias ACL mutation fails when the replacement is not ready' 0 "$status"
  assertStringContains 'alias ACL readiness failure is reported' \
    'Nginx did not pass config readiness checks' "$output"
  after="$(find "$CONFIG_DIR" -type f -exec cksum {} + | sort)"
  assertEquals 'failed alias ACL restores saved and generated config byte-for-byte' "$before" "$after"
  _alias_acl_assert_include "$alias" 80 "$primary"
  assertFalse 'failed alias ACL must not leave a detached policy include' \
    "[ -e '$CONFIG_DIR/nginx_conf/conf.d/security_ip/$alias.inc' ]"
  assertTrue 'failed alias ACL attempts to restore the old proxy runtime' \
    "awk '/subcommand=exec nginx-proxy nginx -t -c/ { failed_ready=1 } /subcommand=run -d --name nginx-proxy/ { if (failed_ready) restored=1 } END { exit !restored }' '$docker_log'"
}
