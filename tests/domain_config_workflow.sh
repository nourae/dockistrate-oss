#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_workflow.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "command failed: $*"; }; }

run_cli init-domain-config example.com
[ -f "$DOMAIN/config/backend.csv" ] || fail_test 'template missing'
[ ! -e "$DOMAIN/runtime/applied" ] || fail_test 'initialization activated a draft'
if "$BIN" validate-domain-config example.com >/dev/null 2>&1; then fail_test 'accepted missing image'; fi
test_domain_csv_set "$DOMAIN/config/backend.csv" image nginx:alpine
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n18180,8080,http,,,no,off,,off,auto\n' >"$DOMAIN/config/ports.csv"
run_cli validate-domain-config example.com
run_cli apply-domain-config example.com --dry-run
[ ! -e "$DOMAIN/runtime/applied" ] || fail_test 'preview activated a draft'
run_cli apply-domain-config example.com
[ -f "$DOMAIN/runtime/applied/backend.csv" ] || fail_test 'apply did not publish snapshot'
grep -q 'listen 18180' "$DOMAIN/generated/nginx/http.conf" || fail_test 'missing domain-generated server'

# A draft never changes generated output until explicitly applied.
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$DOMAIN/config/settings.csv"
if "$BIN" set-backend-http-version example.com http2 >"$TEST_WORK/output" 2>&1; then fail_test 'CLI overwrote pending draft'; fi
[ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = 'http1.0' ] || fail_test 'pending draft lost'
run_cli update-nginx-config
! [ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http1.0' ] || fail_test 'regenerate activated draft'
run_cli apply-domain-config example.com
[ "$(test_csv_field "$DOMAIN/runtime/applied/settings.csv" http_version)" = 'http1.0' ] || fail_test 'manual apply lost value'
run_cli set-backend-http-version example.com http1.1
[ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = 'http1.1' ] || fail_test 'CLI did not update editable source'

# Stopping is declarative and must not erase the listener.
run_cli stop-backend example.com
[ "$(test_csv_field "$DOMAIN/config/backend.csv" state)" = 'stopped' ] || fail_test 'stop did not update source'
grep -q 'down;' "$TEST_WORK/state/config/nginx_conf/conf.d/backends.conf" || fail_test 'stopped backend has live upstream'
run_cli apply-domain-config example.com
[ "$(test_csv_field "$DOMAIN/runtime/applied/backend.csv" state)" = 'stopped' ] || fail_test 'apply restarted stopped backend'

# Invalid drafts remain readable as pending state while other operations work.
printf 'invalid\n' >"$DOMAIN/config/headers.csv"
run_cli status
grep -q 'invalid draft' "$TEST_WORK/output" || fail_test 'status did not report invalid draft'
if "$BIN" apply-domain-config example.com >/dev/null 2>&1; then fail_test 'invalid draft applied'; fi
grep -q '^invalid$' "$DOMAIN/config/headers.csv" || fail_test 'failed apply overwrote draft'
printf '[PASS] domain configuration workflow\n'
