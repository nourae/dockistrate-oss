#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/lib/state_sandbox.sh
source "${ROOT_DIR}/tests/lib/state_sandbox.sh"
GLOB_SENTINEL="${ROOT_DIR}/TLSv1.3"
GLOB_SENTINEL_CREATED="no"

function cleanup_glob_sentinel() {
  if [ "$GLOB_SENTINEL_CREATED" = "yes" ]; then
    rm -f "$GLOB_SENTINEL"
    GLOB_SENTINEL_CREATED="no"
  fi
}

function cleanup() {
  cleanup_glob_sentinel
  dockistrate_test_state_sandbox_restore
}
trap cleanup EXIT

dockistrate_test_state_sandbox "$ROOT_DIR"

CONFIG_DIR="${ROOT_DIR}/state/config"
CUSTOM_HEADERS_FILE="${CONFIG_DIR}/custom_headers.csv"
BACKEND_HEADERS_FILE="${CONFIG_DIR}/backend_headers.csv"
BACKEND_ALIASES_FILE="${CONFIG_DIR}/backend_aliases.csv"
BACKEND_HTTP_FILE="${CONFIG_DIR}/backend_http_versions.csv"
BACKEND_MTLS_FILE="${CONFIG_DIR}/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="${CONFIG_DIR}/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="${CONFIG_DIR}/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="${CONFIG_DIR}/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="${CONFIG_DIR}/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="${CONFIG_DIR}/backend_security_rule_statuses.csv"
SECURITY_IP_RULES_FILE="${CONFIG_DIR}/security_ip_rules.csv"
SECURITY_RULES_FILE="${CONFIG_DIR}/security_rules.csv"
NGINX_DIRECTIVES_FILE="${CONFIG_DIR}/nginx_directives.csv"
ACCESS_LOG_FIELDS_FILE="${CONFIG_DIR}/access_log_fields.csv"
GLOBAL_SETTINGS_FILE="${CONFIG_DIR}/global_settings.csv"
PORT_TLS_PROTOCOLS_FILE="${CONFIG_DIR}/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="${CONFIG_DIR}/port_tls_ciphers.csv"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function run_cmd() {
  (cd "$ROOT_DIR" && SKIP_DOCKER_CHECKS=true ./dockistrate.sh "$@")
}

function expect_update_failure_contains() {
  local expected="$1"
  local output=""
  if output="$(run_cmd update-nginx-config 2>&1)"; then
    fail_test "Expected update-nginx-config to fail"
  fi
  case "$output" in
  *"$expected"*) ;;
  *)
    echo "$output" >&2
    fail_test "Expected update-nginx-config output to contain: ${expected}"
    ;;
  esac
}

function write_valid_header_state() {
  printf '%s\n' \
    'header_type,header_name,header_value' \
    'response,X-Good,ok' >"$CUSTOM_HEADERS_FILE"
  printf '%s\n' \
    'domain,header_type,header_name,header_value' \
    'render-validation.test,response,X-Backend,ok' >"$BACKEND_HEADERS_FILE"
}

function write_valid_tls_state() {
  awk -F',' -v OFS=',' '
    $1 == "TLS_PROTOCOLS" { $2 = "TLSv1.2 TLSv1.3"; saw_protocols = 1 }
    $1 == "TLS_CIPHERS" { $2 = "HIGH:!aNULL:!MD5"; saw_ciphers = 1 }
    { print }
    END {
      if (!saw_protocols) print "TLS_PROTOCOLS", "TLSv1.2 TLSv1.3"
      if (!saw_ciphers) print "TLS_CIPHERS", "HIGH:!aNULL:!MD5"
    }
  ' "$GLOBAL_SETTINGS_FILE" >"${GLOBAL_SETTINGS_FILE}.tmp"
  mv "${GLOBAL_SETTINGS_FILE}.tmp" "$GLOBAL_SETTINGS_FILE"
  printf '%s\n' \
    'listen_port,tls_protocols' \
    '18443,TLSv1.3' >"$PORT_TLS_PROTOCOLS_FILE"
  printf '%s\n' \
    'listen_port,tls_ciphers' \
    '18443,HIGH:!aNULL:!MD5' >"$PORT_TLS_CIPHERS_FILE"
}

function rewrite_state_domain_case() {
  local file="$1" old_domain="$2" new_domain="$3"
  [ -f "$file" ] || return 0
  awk -F',' -v OFS=',' -v old_domain="$old_domain" -v new_domain="$new_domain" '
    NR == 1 { print; next }
    {
      for (i = 1; i <= NF; i++) {
        if ($i == old_domain) {
          $i = new_domain
        }
      }
      print
    }
  ' "$file" >"${file}.tmp"
  mv "${file}.tmp" "$file"
}

function rewrite_alias_target_case() {
  local old_domain="$1" new_domain="$2"
  awk -F',' -v OFS=',' -v old_domain="$old_domain" -v new_domain="$new_domain" '
    NR == 1 { print; next }
    ($1 == "alias" || $1 == "dedicated") && $3 == old_domain { $3 = new_domain }
    { print }
  ' "$BACKEND_ALIASES_FILE" >"${BACKEND_ALIASES_FILE}.tmp"
  mv "${BACKEND_ALIASES_FILE}.tmp" "$BACKEND_ALIASES_FILE"
}

function assert_exact_filename_present() {
  local dir="$1" filename="$2"
  [ -d "$dir" ] || fail_test "Expected directory to exist: ${dir}"
  if ! ls -1 "$dir" | grep -Fxq "$filename"; then
    fail_test "Expected exact filename '${filename}' in ${dir}"
  fi
}

function assert_exact_filename_absent() {
  local dir="$1" filename="$2"
  [ -d "$dir" ] || return 0
  if ls -1 "$dir" | grep -Fxq "$filename"; then
    fail_test "Unexpected exact filename '${filename}' in ${dir}"
  fi
}

function seed_dedicated_host_override_state() {
  local host="$1" mixed_host="$2"

  printf '%s\n' \
    'domain,http_version' \
    "${mixed_host},http1.1" >"$BACKEND_HTTP_FILE"
  printf '%s\n' \
    'domain,header_type,header_name,header_value' \
    "${mixed_host},response,X-Stale-Override,stale" >"$BACKEND_HEADERS_FILE"
  printf '%s\n' \
    'domain,client_ip_header_name' \
    "${mixed_host},X-Stale-Client-IP" >"$BACKEND_CLIENT_IP_HEADER_FILE"
  printf '%s\n' \
    'domain,proxy_ip_header_name' \
    "${mixed_host},X-Stale-Proxy-IP" >"$BACKEND_PROXY_IP_HEADER_FILE"
  printf '%s\n' \
    'domain,acl_policy' \
    "${mixed_host},allow" >"$BACKEND_ACL_POLICY_FILE"
  printf '%s\n' \
    'domain,acl_status_code' \
    "${mixed_host},451" >"$BACKEND_ACL_STATUS_FILE"
  printf '%s\n' \
    'domain,security_rule_status_code' \
    "${mixed_host},452" >"$BACKEND_SECURITY_RULE_STATUS_FILE"
  printf '%s\n' \
    'enabled,domain,scope,action,ip_value,status_code' \
    "1,${mixed_host},l7,deny,192.0.2.55,451" >"$SECURITY_IP_RULES_FILE"
  printf '%s\n' \
    'scope,domain,listen_port,path_prefix,directive_mode,directive_name,directive_value' \
    "backend,${mixed_host},,,managed,send_timeout,24s" >"$NGINX_DIRECTIVES_FILE"

  printf '%s\n' \
    'domain,mtls_directory' \
    "${mixed_host},${ROOT_DIR}/state/certs/mtls/${host}" >"$BACKEND_MTLS_FILE"

  {
    local empty_selector_i
    printf '%s\n' 'enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location'
    printf '1,%s,single,,1,header,X-Stale-Override,equals,yes' "$mixed_host"
    for empty_selector_i in 2 3 4 5 6 7 8 9 10; do
      printf ',,,,'
    done
    printf ',-,test\n'
  } >"$SECURITY_RULES_FILE"
}

function assert_domain_absent_from_state_file() {
  local file="$1" domain="$2"
  if [ -f "$file" ] && grep -Fiq "$domain" "$file"; then
    fail_test "Expected ${domain} to be removed from ${file}"
  fi
}

function assert_dedicated_host_override_state_removed() {
  local host="$1"
  assert_domain_absent_from_state_file "$BACKEND_HTTP_FILE" "$host"
  assert_domain_absent_from_state_file "$BACKEND_HEADERS_FILE" "$host"
  assert_domain_absent_from_state_file "$BACKEND_MTLS_FILE" "$host"
  assert_domain_absent_from_state_file "$BACKEND_CLIENT_IP_HEADER_FILE" "$host"
  assert_domain_absent_from_state_file "$BACKEND_PROXY_IP_HEADER_FILE" "$host"
  assert_domain_absent_from_state_file "$BACKEND_ACL_POLICY_FILE" "$host"
  assert_domain_absent_from_state_file "$BACKEND_ACL_STATUS_FILE" "$host"
  assert_domain_absent_from_state_file "$BACKEND_SECURITY_RULE_STATUS_FILE" "$host"
  assert_domain_absent_from_state_file "$SECURITY_IP_RULES_FILE" "$host"
  assert_domain_absent_from_state_file "$SECURITY_RULES_FILE" "$host"
  assert_domain_absent_from_state_file "$NGINX_DIRECTIVES_FILE" "$host"
}

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend render-validation.test nginx:alpine 18180 http --listen 18192 --no-expose >/dev/null
write_valid_header_state

printf '%s\n' \
  'header_type,header_name,header_value' \
  'invalid,X-Good,ok' >"$CUSTOM_HEADERS_FILE"
expect_update_failure_contains "type 'invalid' must be request or response"

write_valid_header_state
printf '%s\n' \
  'header_type,header_name,header_value' \
  'response,X-Bad;return,ok' >"$CUSTOM_HEADERS_FILE"
expect_update_failure_contains "header name 'X-Bad;return' is invalid"

write_valid_header_state
printf 'header_type,header_name,header_value\nresponse,X-Good,bad\tvalue\n' >"$CUSTOM_HEADERS_FILE"
expect_update_failure_contains "header value for 'X-Good' is invalid"

write_valid_header_state
printf '%s\n' \
  'domain,header_type,header_name,header_value' \
  'bad;domain,response,X-Backend,ok' >"$BACKEND_HEADERS_FILE"
expect_update_failure_contains "domain 'bad;domain' is invalid"

write_valid_header_state
printf '%s\n' \
  'domain,header_type,header_name,header_value' \
  ',response,X-Backend,ok' >"$BACKEND_HEADERS_FILE"
expect_update_failure_contains "domain cannot be empty"

write_valid_header_state
printf '%s\n' \
  'domain,header_type,header_name,header_value' \
  'render-validation.test,response,X-Bad;return,ok' >"$BACKEND_HEADERS_FILE"
expect_update_failure_contains "header name 'X-Bad;return' is invalid"

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend access-log-render-validation.test nginx:alpine 18180 http --listen 18193 --no-expose >/dev/null
printf '%s\n' \
  'log_field' \
  "\$remote_addr'; return 418; #" >"$ACCESS_LOG_FIELDS_FILE"
expect_update_failure_contains "Invalid access log field in ${ACCESS_LOG_FIELDS_FILE} at line 2"
if grep -R "return 418" "${CONFIG_DIR}/nginx_conf" >/dev/null 2>&1; then
  fail_test "tampered access log field should not be rendered into nginx.conf"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend access-log-create-render-validation.test nginx:alpine 18181 http --listen 18194 --no-expose >/dev/null
printf '%s\n' \
  'log_field' \
  "\$remote_addr'; return 419; #" >"$ACCESS_LOG_FIELDS_FILE"
rm -f "${CONFIG_DIR}/nginx_conf/nginx.conf"
if output="$(run_cmd remove-backend access-log-create-render-validation.test 2>&1)"; then
  fail_test "Expected remove-backend to fail when create_nginx_config rejects tampered access log state"
fi
case "$output" in
*"Invalid access log field in ${ACCESS_LOG_FIELDS_FILE} at line 2"*) ;;
*)
  echo "$output" >&2
  fail_test "Expected remove-backend output to include access log field validation failure"
  ;;
esac
if grep -R "return 419" "${CONFIG_DIR}/nginx_conf" >/dev/null 2>&1; then
  fail_test "tampered access log field should not be rendered through missing nginx.conf path"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend access-log-blank-render-validation.test nginx:alpine 18182 http --listen 18195 --no-expose >/dev/null
printf '%s\n' \
  'log_field' \
  '' >"$ACCESS_LOG_FIELDS_FILE"
expect_update_failure_contains "field must be non-empty"

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend access-log-directory-render-validation.test nginx:alpine 18183 http --listen 18196 --no-expose >/dev/null
rm -f "$ACCESS_LOG_FIELDS_FILE"
mkdir "$ACCESS_LOG_FIELDS_FILE"
expect_update_failure_contains "Access log fields state is not a regular file: ${ACCESS_LOG_FIELDS_FILE}"

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend access-log-symlink-render-validation.test nginx:alpine 18184 http --listen 18197 --no-expose >/dev/null
rm -f "$ACCESS_LOG_FIELDS_FILE"
mkdir -p "${CONFIG_DIR}/access_log_fields_target"
ln -s "${CONFIG_DIR}/access_log_fields_target" "$ACCESS_LOG_FIELDS_FILE"
expect_update_failure_contains "Access log fields state is not a regular file: ${ACCESS_LOG_FIELDS_FILE}"

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend tls-render.test nginx:alpine 9443 https --listen 18443 --no-expose >/dev/null
write_valid_tls_state

awk -F',' -v OFS=',' '$1 == "TLS_PROTOCOLS" { $2 = "TLSv1.3;return" } { print }' "$GLOBAL_SETTINGS_FILE" >"${GLOBAL_SETTINGS_FILE}.tmp"
mv "${GLOBAL_SETTINGS_FILE}.tmp" "$GLOBAL_SETTINGS_FILE"
expect_update_failure_contains "Invalid TLS protocol"

write_valid_tls_state
awk -F',' -v OFS=',' '$1 == "TLS_PROTOCOLS" { $2 = "\"   \"" } { print }' "$GLOBAL_SETTINGS_FILE" >"${GLOBAL_SETTINGS_FILE}.tmp"
mv "${GLOBAL_SETTINGS_FILE}.tmp" "$GLOBAL_SETTINGS_FILE"
expect_update_failure_contains "protocol list cannot be empty"

write_valid_tls_state
if [ ! -e "$GLOB_SENTINEL" ]; then
  touch "$GLOB_SENTINEL"
  GLOB_SENTINEL_CREATED="yes"
fi
awk -F',' -v OFS=',' '$1 == "TLS_PROTOCOLS" { $2 = "TLSv1.*" } { print }' "$GLOBAL_SETTINGS_FILE" >"${GLOBAL_SETTINGS_FILE}.tmp"
mv "${GLOBAL_SETTINGS_FILE}.tmp" "$GLOBAL_SETTINGS_FILE"
expect_update_failure_contains "Invalid TLS protocol"
cleanup_glob_sentinel

write_valid_tls_state
awk -F',' -v OFS=',' '$1 == "TLS_CIPHERS" { $2 = "BAD;return" } { print }' "$GLOBAL_SETTINGS_FILE" >"${GLOBAL_SETTINGS_FILE}.tmp"
mv "${GLOBAL_SETTINGS_FILE}.tmp" "$GLOBAL_SETTINGS_FILE"
expect_update_failure_contains "cipher string contains unsafe Nginx directive characters"

write_valid_tls_state
printf '%s\n' \
  'listen_port,tls_protocols' \
  'notaport,TLSv1.3' >"$PORT_TLS_PROTOCOLS_FILE"
expect_update_failure_contains "port 'notaport' is invalid"

write_valid_tls_state
printf '%s\n' \
  'listen_port,tls_protocols' \
  '18443,"   "' >"$PORT_TLS_PROTOCOLS_FILE"
expect_update_failure_contains "protocol list cannot be empty"

write_valid_tls_state
printf '%s\n' \
  'listen_port,tls_ciphers' \
  '18443,BAD;return' >"$PORT_TLS_CIPHERS_FILE"
expect_update_failure_contains "cipher string contains unsafe Nginx directive characters"

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend cert-render-validation.test nginx:alpine 9444 http --listen 18194 --no-expose >/dev/null
run_cmd add-port cert-render-validation.test 18444 9444 https none no >/dev/null
if ! run_cmd update-nginx-config >/dev/null; then
  fail_test "Expected valid persisted relative certificate reference to render"
fi

conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
before_conf="$(cat "$conf_file")"

awk -F',' -v OFS=',' '
  $1 == "port" && $2 == "cert-render-validation.test" && $7 == "18444" {
    $10 = "../outside"
  }
  { print }
' "${CONFIG_DIR}/backend_ports.csv" >"${CONFIG_DIR}/backend_ports.csv.tmp"
mv "${CONFIG_DIR}/backend_ports.csv.tmp" "${CONFIG_DIR}/backend_ports.csv"

expect_update_failure_contains "certificate reference '../outside' is invalid for HTTPS mapping 'cert-render-validation.test:18444'"

after_conf="$(cat "$conf_file")"
if [ "$before_conf" != "$after_conf" ]; then
  fail_test "backends.conf should be rolled back after tampered certificate reference validation failure"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend alias-render-validation.test nginx:alpine 18180 http >/dev/null
run_cmd add-host-alias alias.alias-render-validation.test alias-render-validation.test >/dev/null
if ! run_cmd update-nginx-config >/dev/null; then
  fail_test "Expected valid alias state to render"
fi

conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
before_conf="$(cat "$conf_file")"

awk -F',' -v OFS=',' '
  $1 == "alias" && $2 == "alias.alias-render-validation.test" {
    $2 = "alias.alias-render-validation.test; return 418; #"
  }
  { print }
' "$BACKEND_ALIASES_FILE" >"${BACKEND_ALIASES_FILE}.tmp"
mv "${BACKEND_ALIASES_FILE}.tmp" "$BACKEND_ALIASES_FILE"

expect_update_failure_contains "alias hostname 'alias.alias-render-validation.test; return 418; #' is invalid"

after_conf="$(cat "$conf_file")"
if [ "$before_conf" != "$after_conf" ]; then
  fail_test "backends.conf should be rolled back after tampered alias hostname validation failure"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend dedicated-render-validation.test nginx:alpine 18180 http >/dev/null
run_cmd add-dedicated-host admin.dedicated-render-validation.test dedicated-render-validation.test >/dev/null
if ! run_cmd update-nginx-config >/dev/null; then
  fail_test "Expected valid dedicated host state to render"
fi

conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
before_conf="$(cat "$conf_file")"
bad_dedicated_host='admin.dedicated-render-validation.test; return 418; #'
bad_dedicated_host_include="$(printf '%s' "$bad_dedicated_host" | sed 's/[^a-zA-Z0-9\.\-]/-/g')"

awk -F',' -v OFS=',' -v bad_host="$bad_dedicated_host" '
  $1 == "dedicated" && $2 == "admin.dedicated-render-validation.test" {
    $2 = bad_host
  }
  { print }
' "$BACKEND_ALIASES_FILE" >"${BACKEND_ALIASES_FILE}.tmp"
mv "${BACKEND_ALIASES_FILE}.tmp" "$BACKEND_ALIASES_FILE"

expect_update_failure_contains "dedicated hostname 'admin.dedicated-render-validation.test; return 418; #' is invalid"

after_conf="$(cat "$conf_file")"
if [ "$before_conf" != "$after_conf" ]; then
  fail_test "backends.conf should be rolled back after tampered dedicated host validation failure"
fi
if grep -Fq "$bad_dedicated_host" "$conf_file"; then
  fail_test "tampered dedicated host should not be rendered in backends.conf"
fi
if [ -e "${CONFIG_DIR}/nginx_conf/conf.d/security_ip/${bad_dedicated_host_include}.inc" ]; then
  fail_test "tampered dedicated host should not generate a security_ip include"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend alias-target-render-validation.test nginx:alpine 18180 http >/dev/null
run_cmd add-host-alias alias-target.alias-render-validation.test alias-target-render-validation.test >/dev/null
if ! run_cmd update-nginx-config >/dev/null; then
  fail_test "Expected valid alias target state to render"
fi

conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
before_conf="$(cat "$conf_file")"

awk -F',' -v OFS=',' '
  $1 == "alias" && $2 == "alias-target.alias-render-validation.test" {
    $3 = "alias-target-render-validation.test; return 418; #"
  }
  { print }
' "$BACKEND_ALIASES_FILE" >"${BACKEND_ALIASES_FILE}.tmp"
mv "${BACKEND_ALIASES_FILE}.tmp" "$BACKEND_ALIASES_FILE"

expect_update_failure_contains "target domain 'alias-target-render-validation.test; return 418; #' is invalid"

after_conf="$(cat "$conf_file")"
if [ "$before_conf" != "$after_conf" ]; then
  fail_test "backends.conf should be rolled back after tampered alias target validation failure"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend cleanup-target-case.test nginx:alpine 18180 http >/dev/null
run_cmd add-host-alias alias.cleanup-target-case.test cleanup-target-case.test >/dev/null
run_cmd add-dedicated-host admin.cleanup-target-case.test cleanup-target-case.test >/dev/null
rewrite_alias_target_case cleanup-target-case.test Cleanup-Target-Case.TEST
if ! run_cmd remove-backend cleanup-target-case.test >/dev/null; then
  fail_test "Expected remove-backend to remove alias rows with normalized mixed-case targets"
fi
if [ -f "$BACKEND_ALIASES_FILE" ] && grep -Fiq 'cleanup-target-case.test' "$BACKEND_ALIASES_FILE"; then
  fail_test "remove-backend should remove alias rows with mixed-case target domains"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend cleanall-target-case.test nginx:alpine 18180 http >/dev/null
run_cmd add-host-alias alias.cleanall-target-case.test cleanall-target-case.test >/dev/null
run_cmd add-dedicated-host admin.cleanall-target-case.test cleanall-target-case.test >/dev/null
rewrite_alias_target_case cleanall-target-case.test Cleanall-Target-Case.TEST
if ! run_cmd clean-all cleanall-target-case.test >/dev/null; then
  fail_test "Expected clean-all to remove alias rows with normalized mixed-case targets"
fi
if [ -f "$BACKEND_ALIASES_FILE" ] && grep -Fiq 'cleanall-target-case.test' "$BACKEND_ALIASES_FILE"; then
  fail_test "clean-all should remove alias rows with mixed-case target domains"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend remove-override-a.test nginx:alpine 18180 http >/dev/null
run_cmd add-dedicated-host admin.remove-override.test remove-override-a.test >/dev/null
seed_dedicated_host_override_state admin.remove-override.test Admin.Remove-Override.TEST
if ! run_cmd remove-backend remove-override-a.test >/dev/null; then
  fail_test "Expected remove-backend to purge mixed-case dedicated host override state"
fi
assert_dedicated_host_override_state_removed admin.remove-override.test

run_cmd add-backend remove-override-b.test nginx:alpine 18180 http >/dev/null
run_cmd add-dedicated-host admin.remove-override.test remove-override-b.test >/dev/null
if grep -Fq 'admin.remove-override.test' "$BACKEND_HTTP_FILE" 2>/dev/null; then
  fail_test "re-added dedicated host should not inherit stale HTTP version override"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend cleanall-override-a.test nginx:alpine 18180 http >/dev/null
run_cmd add-dedicated-host admin.cleanall-override.test cleanall-override-a.test >/dev/null
seed_dedicated_host_override_state admin.cleanall-override.test Admin.Cleanall-Override.TEST
if ! run_cmd clean-all cleanall-override-a.test >/dev/null; then
  fail_test "Expected clean-all to purge mixed-case dedicated host override state"
fi
assert_dedicated_host_override_state_removed admin.cleanall-override.test

run_cmd add-backend cleanall-override-b.test nginx:alpine 18180 http >/dev/null
run_cmd add-dedicated-host admin.cleanall-override.test cleanall-override-b.test >/dev/null
if grep -Fq 'admin.cleanall-override.test' "$BACKEND_HTTP_FILE" 2>/dev/null; then
  fail_test "re-added dedicated host should not inherit stale clean-all HTTP version override"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend include-case.test nginx:alpine 18180 http >/dev/null
run_cmd add-dedicated-host admin.include-case.test include-case.test >/dev/null
run_cmd add-acl admin.include-case.test l7 deny 192.0.2.77 451 >/dev/null
awk -F',' -v OFS=',' '
  NR == 1 { print; next }
  $1 == "dedicated" && $2 == "admin.include-case.test" { $2 = "Admin.Include-Case.TEST" }
  { print }
' "$BACKEND_ALIASES_FILE" >"${BACKEND_ALIASES_FILE}.tmp"
mv "${BACKEND_ALIASES_FILE}.tmp" "$BACKEND_ALIASES_FILE"
if ! run_cmd update-nginx-config >/dev/null; then
  fail_test "Expected mixed-case dedicated host state to render with normalized include filenames"
fi
assert_exact_filename_present "${CONFIG_DIR}/nginx_conf/conf.d/security_ip" 'admin.include-case.test.inc'
assert_exact_filename_absent "${CONFIG_DIR}/nginx_conf/conf.d/security_ip" 'Admin.Include-Case.TEST.inc'

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend backend-include-case.test nginx:alpine 18180 http >/dev/null
run_cmd add-acl backend-include-case.test l7 deny 192.0.2.78 451 >/dev/null
rewrite_state_domain_case "${CONFIG_DIR}/backend_ports.csv" backend-include-case.test Backend-Include-Case.TEST
if ! run_cmd update-nginx-config >/dev/null; then
  fail_test "Expected mixed-case backend port state to render with normalized include filenames"
fi
conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
if ! grep -Fq 'security_ip/backend-include-case.test.inc;' "$conf_file"; then
  fail_test "Expected backend server block to reference normalized security_ip include filename"
fi
if grep -Fq 'Backend-Include-Case.TEST.inc' "$conf_file"; then
  fail_test "Backend server block should not reference mixed-case security_ip include filename"
fi
assert_exact_filename_present "${CONFIG_DIR}/nginx_conf/conf.d/security_ip" 'backend-include-case.test.inc'
assert_exact_filename_absent "${CONFIG_DIR}/nginx_conf/conf.d/security_ip" 'Backend-Include-Case.TEST.inc'

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend backend-case-render.test nginx:alpine 18180 http >/dev/null
run_cmd add-dedicated-host admin.backend-case-render.test backend-case-render.test >/dev/null
rewrite_state_domain_case "${CONFIG_DIR}/backend_ports.csv" backend-case-render.test Backend-Case-Render.TEST
if ! run_cmd update-nginx-config >/dev/null; then
  fail_test "Expected mixed-case backend port state to render dedicated host blocks"
fi
conf_file="${CONFIG_DIR}/nginx_conf/conf.d/backends.conf"
if ! grep -Fq 'Dedicated host mapping for admin.backend-case-render.test' "$conf_file"; then
  fail_test "Expected dedicated host block to render when backend_ports.csv stores mixed-case backend domains"
fi
if grep -Fq 'Backend-Case-Render.TEST' "$conf_file"; then
  fail_test "Dedicated host render should consume normalized backend domains"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend protected-primary.test nginx:alpine 18180 http >/dev/null
run_cmd set-backend-http-version protected-primary.test http1.1 >/dev/null
run_cmd add-backend collision-owner.test nginx:alpine 18181 http >/dev/null
printf '%s\n' 'dedicated,protected-primary.test,collision-owner.test' >>"$BACKEND_ALIASES_FILE"
collision_output=""
if collision_output="$(run_cmd remove-backend collision-owner.test 2>&1)"; then
  fail_test "Expected remove-backend to fail before deleting render state for a real backend domain"
fi
case "$collision_output" in
*"Refusing to remove domain-keyed render state for 'protected-primary.test'"*) ;;
*)
  echo "$collision_output" >&2
  fail_test "Expected remove-backend collision output to include backend-domain cleanup refusal"
  ;;
esac
if ! grep -Fxq 'protected-primary.test,http1.1' "$BACKEND_HTTP_FILE"; then
  fail_test "Backend-domain cleanup refusal should preserve protected backend HTTP version state"
fi

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend corrupt-guard.test nginx:alpine 18180 http >/dev/null
run_cmd set-backend-http-version corrupt-guard.test http1.1 >/dev/null
run_cmd add-backend corrupt-owner.test nginx:alpine 18181 http >/dev/null
printf '%s\n' 'dedicated,corrupt-guard.test,corrupt-owner.test' >>"$BACKEND_ALIASES_FILE"
awk 'NR == 1 { print "bad_header"; next } { print }' "${CONFIG_DIR}/backend_ports.csv" >"${CONFIG_DIR}/backend_ports.csv.tmp"
mv "${CONFIG_DIR}/backend_ports.csv.tmp" "${CONFIG_DIR}/backend_ports.csv"
corrupt_output=""
if corrupt_output="$(run_cmd remove-dedicated-host corrupt-guard.test 2>&1)"; then
  fail_test "Expected remove-dedicated-host to fail closed when backend_ports.csv is invalid"
fi
case "$corrupt_output" in
*"Invalid header in"*) ;;
*)
  echo "$corrupt_output" >&2
  fail_test "Expected remove-dedicated-host to fail on invalid backend_ports.csv"
  ;;
esac
if ! grep -Fxq 'corrupt-guard.test,http1.1' "$BACKEND_HTTP_FILE"; then
  fail_test "Invalid backend_ports.csv cleanup guard should preserve backend HTTP version state"
fi
if ! grep -Fxq 'dedicated,corrupt-guard.test,corrupt-owner.test' "$BACKEND_ALIASES_FILE"; then
  fail_test "Invalid backend_ports.csv cleanup guard should roll back the dedicated host alias row"
fi
direct_guard_output=""
if direct_guard_output="$(
  cd "$ROOT_DIR" &&
    SKIP_DOCKER_CHECKS=true bash -c 'source ./lib/config.sh; source ./lib/logging.sh; source ./lib/utils.sh; remove_domain_keyed_render_state corrupt-guard.test' 2>&1
)"; then
  fail_test "Expected direct domain-keyed cleanup to fail closed when backend_ports.csv is invalid"
fi
case "$direct_guard_output" in
*"Refusing to remove domain-keyed render state because backend_ports.csv is invalid"*) ;;
*)
  echo "$direct_guard_output" >&2
  fail_test "Expected direct cleanup guard output for invalid backend_ports.csv"
  ;;
esac
if ! grep -Fxq 'corrupt-guard.test,http1.1' "$BACKEND_HTTP_FILE"; then
  fail_test "Direct invalid backend_ports.csv cleanup guard should preserve backend HTTP version state"
fi

echo "[tests] persisted_render_validation.sh: PASS"
