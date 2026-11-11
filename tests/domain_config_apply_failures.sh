#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_failures.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "command failed: $*"; }; }

run_cli init-domain-config example.com
test_domain_csv_set "$DOMAIN/config/backend.csv" image nginx:alpine
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n18180,8080,http,,,no,off,,off,auto\n' >"$DOMAIN/config/ports.csv"
run_cli apply-domain-config example.com
cp "$DOMAIN/runtime/applied/settings.csv" "$TEST_WORK/applied-before"
cp "$DOMAIN/generated/nginx/http.conf" "$TEST_WORK/nginx-before"
cp "$TEST_WORK/state/config/backend_http_versions.csv" "$TEST_WORK/runtime-before"

# Simulate an operator editing the source after the validated candidate was
# captured, then force rendering to fail after the aggregate was published.
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$DOMAIN/config/settings.csv"
cat >"$TEST_WORK/lib/domain_config/zz_apply_race.sh" <<'EOF'
# shellcheck shell=bash
function domain_config_provision_certificates() {
  printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp2,,,,,\n' >"${STATE_DIR}/domains/example.com/config/settings.csv"
}
EOF
cat >"$TEST_WORK/lib/nginx/zz_apply_failure.sh" <<'EOF'
# shellcheck shell=bash
function update_nginx_config() {
  printf '# partial output\n' >"${NGINX_HTTP_CONF_DIR}/backends.conf"
  return 1
}
EOF
if "$BIN" apply-domain-config example.com >"$TEST_WORK/output" 2>&1; then fail_test 'injected render failure succeeded'; fi
rm "$TEST_WORK/lib/nginx/zz_apply_failure.sh"
[ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = 'http2' ] || fail_test 'rollback overwrote concurrent source edit'
cmp -s "$TEST_WORK/applied-before" "$DOMAIN/runtime/applied/settings.csv" || fail_test 'failed apply published candidate snapshot'
cmp -s "$TEST_WORK/nginx-before" "$DOMAIN/generated/nginx/http.conf" || fail_test 'failed apply changed domain-generated output'
cmp -s "$TEST_WORK/runtime-before" "$TEST_WORK/state/config/backend_http_versions.csv" || fail_test 'failed apply did not restore aggregate state'

# With the same concurrent edit but a successful apply, only the captured
# candidate becomes active; the later edit stays pending for the next apply.
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$DOMAIN/config/settings.csv"
run_cli apply-domain-config example.com
[ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http1.0' ] || fail_test 'apply used a source edit made after validation'
[ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = 'http2' ] || fail_test 'successful apply overwrote concurrent source edit'
grep -Fq 'remain unapplied' "$TEST_WORK/output" || fail_test 'concurrent edit was not reported as pending'
rm "$TEST_WORK/lib/domain_config/zz_apply_race.sh"
run_cli apply-domain-config example.com
[ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http2' ] || fail_test 'next apply could not activate retained edit'
printf '[PASS] domain apply rollback and source races\n'
