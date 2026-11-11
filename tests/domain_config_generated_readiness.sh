#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/domain_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_generated.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$NGINX_CONFIG_DIR" "$TEST_WORK/candidate/example.com/config"
printf '5\n' >"$CONFIG_DIR/state_schema_version"
printf '# Existing schema-1 proxy configuration.\n' >"$NGINX_CONFIG_DIR/nginx.conf"
domain_config_write_template example.com certificate-only "$TEST_WORK/candidate/example.com/config"
_domain_config_copy_inputs "$TEST_WORK/candidate/example.com/config" "$DOMAINS_DIR/example.com/runtime/applied"
SKIP_DOCKER_CHECKS=true

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function domain_config_runtime_preview() { :; }
function get_all_mapped_port_bindings() { :; }
function _domain_config_effective_setting() { _dc_effective_value=default; _dc_effective_source=global; }

# Source/applied equality and an existing nginx.conf do not prove that the
# migrated installation has rendered its domain-owned artifacts.
if domain_config_runtime_matches "$TEST_WORK/candidate"; then fail_test 'migrated layout was treated as rendered'; fi
_domain_config_publish_generated
[ -f "$DOMAINS_DIR/example.com/generated/nginx/http.conf" ] || fail_test 'operational publication did not produce its placeholder'
[ ! -e "$NGINX_CONFIG_DIR/domain_layout_version" ] || fail_test 'operational publication marked the layout rendered'
if domain_config_runtime_matches "$TEST_WORK/candidate"; then fail_test 'operational placeholders bypassed the first apply'; fi
_domain_config_preview_proxy "$TEST_WORK/candidate" false '' >"$TEST_WORK/preview"
grep -Fq 'refresh per-domain configuration and proxy layout' "$TEST_WORK/preview" || fail_test 'preview omitted first-render work'
grep -Fq 'Proxy: reload' "$TEST_WORK/preview" || fail_test 'preview incorrectly promised no reload'

# Starting or failing a render cannot establish freshness. Only the renderer's
# successful tail writes the marker, which is inside its CONFIG_DIR transaction.
_domain_config_render_begin
[ ! -e "$NGINX_CONFIG_DIR/domain_layout_version" ] || fail_test 'incomplete render marked the layout current'
_domain_config_render_complete
_domain_config_publish_generated
domain_config_runtime_matches "$TEST_WORK/candidate" || fail_test 'completed layout did not retain no-op apply'
_domain_config_preview_proxy "$TEST_WORK/candidate" false '' >"$TEST_WORK/preview"
grep -Fq 'Proxy: unchanged; no reload required.' "$TEST_WORK/preview" || fail_test 'matching layout preview requested a reload'

mv "$DOMAINS_DIR/example.com/generated/nginx/http.conf" "$TEST_WORK/http-before"
if domain_config_runtime_matches "$TEST_WORK/candidate"; then fail_test 'missing domain artifact was ignored'; fi
_domain_config_preview_proxy "$TEST_WORK/candidate" false '' >"$TEST_WORK/preview"
grep -Fq 'refresh per-domain configuration and proxy layout' "$TEST_WORK/preview" || fail_test 'preview omitted missing-artifact repair'
printf '[PASS] domain generated layout readiness and preview\n'
