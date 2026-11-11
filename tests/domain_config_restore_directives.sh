#!/usr/bin/env bash
# Globals are consumed by sourced production helpers in the isolated fixture.
# shellcheck disable=SC2034,SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-restore-directives.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true CERT_AUTOCONFIG_DISABLED=1
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"
DIRECTIVES="$TEST_WORK/state/config/nginx_directives.csv"
DIRECTIVES_HEADER='scope,domain,listen_port,path_prefix,directive_mode,directive_name,directive_value'
DOMAIN_DIRECTIVES_HEADER='scope,listen_port,path_prefix,directive_mode,directive_name,directive_value'

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }

# Seed a stopped backend without Docker. Restore still runs the real CLI
# intake, publication, compilation, rendering and transaction recovery.
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  mkdir -p "$CONFIG_DIR"
  state_csv_ensure_all_state_files
  ENABLE_AUTO_BACKUPS=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
  domain_config_write_template example.com backend "$DOMAIN/config"
  _domain_csv_set "$DOMAIN/config/backend.csv" image nginx:alpine
  _domain_csv_set "$DOMAIN/config/backend.csv" state stopped
  csv_join_row 38080 80 http '' '' no off '' off auto >>"$DOMAIN/config/ports.csv"
  csv_join_row backend '' '' managed send_timeout 77s >>"$DOMAIN/config/nginx_directives.csv"
  csv_join_row global '' '' '' managed proxy_read_timeout 21s >>"$NGINX_DIRECTIVES_FILE"
  csv_join_row global '' '' '' managed client_max_body_size 9m >>"$NGINX_DIRECTIVES_FILE"
)
run_cli apply-domain-config example.com

# A directory archive exercises the public restore format while allowing its
# aggregate domain cache to disagree with its authoritative applied snapshot.
archive="$TEST_WORK/archive"
mkdir -p "$archive/config" "$archive/domains" "$archive/shared"
cp "$TEST_WORK/state/config/"*.csv "$TEST_WORK/state/config/state_schema_version" "$archive/config/"
cp -R "$DOMAIN" "$archive/domains/"
printf 'format_version,state_schema_version\n5,5\n' >"$archive/backup_manifest.csv"
printf '%s\n' "$DIRECTIVES_HEADER" \
  'global,,,,managed,proxy_read_timeout,11s' \
  'stream-global,,,,managed,proxy_timeout,31s' \
  'backend,example.com,,,managed,send_timeout,99s' >"$archive/config/nginx_directives.csv"
printf '%s\n' "$DOMAIN_DIRECTIVES_HEADER" 'backend,,,managed,send_timeout,23s' >"$archive/domains/example.com/runtime/applied/nginx_directives.csv"
printf '%s\n' "$DOMAIN_DIRECTIVES_HEADER" 'backend,,,managed,send_timeout,29s' >"$archive/domains/example.com/config/nginx_directives.csv"

run_cli restore-backup "$archive"
printf '%s\n' "$DIRECTIVES_HEADER" \
  'global,,,,managed,proxy_read_timeout,11s' \
  'stream-global,,,,managed,proxy_timeout,31s' \
  'backend,example.com,,,managed,send_timeout,23s' >"$TEST_WORK/expected-directives"
cmp -s "$TEST_WORK/expected-directives" "$DIRECTIVES" || fail_test 'Restore did not replace global directives and rebuild domain rows from archived applied state'
grep -q 'send_timeout 23s;' "$DOMAIN/generated/nginx/http.conf" || fail_test 'Restored applied domain directive was not rendered'
cmp -s "$archive/domains/example.com/config/nginx_directives.csv" "$DOMAIN/config/nginx_directives.csv" || fail_test 'Restore lost the archived pending directive draft'
grep -Rq 'proxy_read_timeout 11s;' "$TEST_WORK/state/config/nginx_conf" || fail_test 'Restored HTTP global directive was not rendered'
grep -Rq 'proxy_timeout 31s;' "$TEST_WORK/state/config/nginx_conf" || fail_test 'Restored stream global directive was not rendered'
if grep -Rq 'client_max_body_size 9m;' "$TEST_WORK/state/config/nginx_conf"; then
  fail_test 'Restore retained a current-only global directive in generated configuration'
fi

# Fail only after real rendering has consumed different archived globals. The
# transaction must restore both the previous mixed CSV and generated files.
cp "$DIRECTIVES" "$TEST_WORK/before-directives"
cp -R "$TEST_WORK/state/config/nginx_conf" "$TEST_WORK/before-nginx"
cp -R "$DOMAIN/generated" "$TEST_WORK/before-domain-generated"
printf '%s\n' "$DIRECTIVES_HEADER" \
  'global,,,,managed,proxy_read_timeout,17s' \
  'stream-global,,,,managed,proxy_timeout,35s' \
  'backend,example.com,,,managed,send_timeout,23s' >"$TEST_WORK/failed-directives-expected"
cp "$TEST_WORK/failed-directives-expected" "$archive/config/nginx_directives.csv"
cat >"$TEST_WORK/lib/nginx/zz_restore_directives_test.sh" <<'HOOK'
# shellcheck shell=bash
eval "$(declare -f _update_nginx_config_from_validated_settings | sed '1s/_update_nginx_config_from_validated_settings/_test_restore_directives_render/')"
function _update_nginx_config_from_validated_settings() {
  _test_restore_directives_render || return 1
  if [ "${FAIL_RESTORE_DIRECTIVES_ACTIVATION:-false}" = true ]; then
    cp "$NGINX_DIRECTIVES_FILE" "$BASE_DIR/failed-directives-observed" || return 1
    printf '[Error] Injected failure after restore directive rendering.\n' >&2
    return 1
  fi
}
HOOK
if FAIL_RESTORE_DIRECTIVES_ACTIVATION=true "$BASH" "$BIN" restore-backup "$archive" >"$TEST_WORK/output" 2>&1; then
  fail_test 'Restore ignored a late activation failure'
fi
cmp -s "$TEST_WORK/failed-directives-expected" "$TEST_WORK/failed-directives-observed" || fail_test 'Failure injection did not reach publication of archived global directives'
cmp -s "$TEST_WORK/before-directives" "$DIRECTIVES" || fail_test 'Failed restore did not roll back global directives'
diff -r "$TEST_WORK/before-nginx" "$TEST_WORK/state/config/nginx_conf" >/dev/null || fail_test 'Failed restore changed generated shared configuration'
diff -r "$TEST_WORK/before-domain-generated" "$DOMAIN/generated" >/dev/null || fail_test 'Failed restore changed generated domain configuration'

# Absence in the archive means no global directives, while domain rows must
# still be compiled from the saved applied snapshot.
rm "$archive/config/nginx_directives.csv"
run_cli restore-backup "$archive"
printf '%s\n' "$DIRECTIVES_HEADER" 'backend,example.com,,,managed,send_timeout,23s' >"$TEST_WORK/expected-directives"
cmp -s "$TEST_WORK/expected-directives" "$DIRECTIVES" || fail_test 'Archive without directives did not clear live globals and rebuild domain rows'
if grep -RqE 'proxy_read_timeout (11|17|21)s;|proxy_timeout (31|35)s;|client_max_body_size 9m;' "$TEST_WORK/state/config/nginx_conf"; then
  fail_test 'Archive without directives retained an old generated global override'
fi
grep -q 'send_timeout 23s;' "$DOMAIN/generated/nginx/http.conf" || fail_test 'Missing aggregate directive file lost the applied domain directive'
printf '[PASS] restore replaces HTTP/stream globals, rebuilds applied domain directives and rolls back failures\n'
