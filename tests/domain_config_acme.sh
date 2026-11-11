#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/certs/common.sh"
source "$ROOT_DIR/lib/domain_config/certificates_commands.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_acme.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
NGINX_CONTAINER_NAME=test-proxy; NGINX_IMAGE=nginx:alpine; NGINX_CONTAINER_MAIN_CONF=/etc/nginx/nginx.conf
MOCK_BINDINGS='443/tcp'
function container_published_port_bindings() { printf '%s\n' "$MOCK_BINDINGS"; }
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
if _certbot_proxy_publishes_http; then fail_test 'HTTPS-only proxy selected HTTP webroot'; fi
MOCK_BINDINGS='80/udp'
if _certbot_proxy_publishes_http; then fail_test 'UDP port 80 selected HTTP webroot'; fi
MOCK_BINDINGS=$'80/tcp\n443/tcp'
_certbot_proxy_publishes_http || fail_test 'HTTP publishing proxy did not select webroot'
function transaction_is_active() { return 0; }
function _nginx_prepare_runtime_rollback() { printf 'prepare\n' >>"$TEST_WORK/actions"; }
function domain_config_runtime_capture_proxy() { printf 'capture\n' >>"$TEST_WORK/actions"; }
function _with_validated_render_settings() { "$@"; }
function fix_default_config() { printf 'default\n' >>"$TEST_WORK/actions"; }
function docker() { [ "$*" = 'exec test-proxy nginx -t -c /etc/nginx/nginx.conf' ] || fail_test 'Unexpected challenge runtime action'; printf 'validate\n' >>"$TEST_WORK/actions"; }
function _nginx_mark_runtime_rollback_needed() { printf 'mark\n' >>"$TEST_WORK/actions"; }
function reload_nginx_if_running() { printf 'reload\n' >>"$TEST_WORK/actions"; }
function update_nginx_config() { fail_test 'Challenge setup rendered incomplete candidate HTTPS state'; }
SKIP_UPDATE_NGINX_CONFIG=true
_domain_config_prepare_acme_challenge
printf 'prepare\ncapture\ndefault\nvalidate\nmark\nreload\n' >"$TEST_WORK/expected"
cmp -s "$TEST_WORK/actions" "$TEST_WORK/expected" || fail_test 'Challenge preparation failed validation or rollback ordering'
printf '[PASS] domain ACME challenge preparation\n'
