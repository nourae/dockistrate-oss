#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-certificate-activation.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true CERT_AUTOCONFIG_DISABLED=1
BIN="$TEST_WORK/dockistrate.sh"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256; }

# Use real CLI publication, rendering, certificate generation and transaction
# recovery. The hook observes activation and can fail it before publication.
cat >"$TEST_WORK/lib/nginx/zz_certificate_activation_test.sh" <<'HOOK'
# shellcheck shell=bash
eval "$(declare -f _update_nginx_config_from_validated_settings | sed '1s/_update_nginx_config_from_validated_settings/_test_certificate_render/')"
function _update_nginx_config_from_validated_settings() {
  local material="$STATE_DIR/domains/example.com/certs/selfsigned-38443/fullchain.pem"
  openssl x509 -in "$material" -noout -fingerprint -sha256 >>"$BASE_DIR/activated"
  [ "${FAIL_CERTIFICATE_ACTIVATION:-false}" != true ] || return 1
  _test_certificate_render
}
HOOK

(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  mkdir -p "$CONFIG_DIR"
  state_csv_ensure_all_state_files
  ENABLE_AUTO_BACKUPS=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
  config="$STATE_DIR/domains/example.com/config"
  domain_config_write_template example.com backend "$config"
  _domain_csv_set "$config/backend.csv" image nginx:alpine
  _domain_csv_set "$config/backend.csv" state stopped
  csv_join_row 38080 80 http '' '' no off '' off auto >>"$config/ports.csv"
  csv_join_row 38443 80 https example.com selfsigned-38443 no off '' off auto >>"$config/ports.csv"
  csv_join_row selfsigned-38443 selfsigned 38443 '' '' >>"$config/certificates.csv"
)

run_cli apply-domain-config example.com
unset CERT_AUTOCONFIG_DISABLED
cp "$TEST_WORK/state/domains/example.com/config/ports.csv" "$TEST_WORK/ports-before.csv"
material="$TEST_WORK/state/domains/example.com/certs/selfsigned-38443/fullchain.pem"
before="$(fingerprint "$material")"
: >"$TEST_WORK/activated"
run_cli replace-cert example.com 38443 selfsigned
after="$(fingerprint "$material")"
[ "$before" != "$after" ] || fail_test 'Replacement did not produce new certificate material'
[ "$(cat "$TEST_WORK/activated")" = "$after" ] || fail_test 'Replacement did not activate its new material exactly once'
cmp -s "$TEST_WORK/state/domains/example.com/config/certificates.csv" "$TEST_WORK/state/domains/example.com/runtime/applied/certificates.csv" || fail_test 'Replacement left mismatched declarations'
for scope in config runtime/applied; do
  cmp -s "$TEST_WORK/ports-before.csv" "$TEST_WORK/state/domains/example.com/$scope/ports.csv" || fail_test 'Replacement changed listeners or enabled an HTTP redirect'
done

# A failed refresh must not report success or retain the unactivated material.
: >"$TEST_WORK/activated"
if FAIL_CERTIFICATE_ACTIVATION=true "$BASH" "$BIN" replace-cert example.com 38443 selfsigned >"$TEST_WORK/output" 2>&1; then
  fail_test 'Replacement ignored activation failure'
fi
[ -s "$TEST_WORK/activated" ] || fail_test 'Failure injection never reached certificate activation'
[ "$(fingerprint "$material")" = "$after" ] || fail_test 'Failed activation did not restore the prior certificate'
printf '[PASS] certificate replacement activates once and restores material on refresh failure\n'
