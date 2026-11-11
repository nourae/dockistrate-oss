#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-schema3-migration.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
mkdir "$TEST_WORK/bin"
cat >"$TEST_WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_TEST_LOG"
exit 99
EOF
chmod +x "$TEST_WORK/bin/docker"
export PATH="$TEST_WORK/bin:$PATH" SKIP_DOCKER_CHECKS=true DOCKER_TEST_LOG="$TEST_WORK/docker.log"
BIN="$TEST_WORK/dockistrate.sh"
cd "$TEST_WORK"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function fingerprint() {
  (cd "$TEST_WORK/state" && find config domains -type f -print | LC_ALL=C sort |
    while IFS= read -r file; do printf '%s\n' "$file"; cksum <"$file"; done)
}

(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"
  _domain_config_bind_config "$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR/nginx_conf/conf.d" "$DOMAINS_DIR/a.example.com/config" "$DOMAINS_DIR/a.example.com/runtime/applied" \
    "$DOMAINS_DIR/b.example.com/config" "$DOMAINS_DIR/c.example.com/runtime/applied" "$DOMAINS_DIR/a.example.com/certs/retained"
  state_security_rules_use_schema 2
  state_csv_ensure_all_state_files
  # These are actual schema-2 bytes, not current serializers with an old marker.
  printf 'setting_key,setting_value\nENABLE_AUTO_BACKUPS,false\nHTTP_VERSION,http1.1\nEXAMPLE_EXTENSION,preserve-me\n' >"$GLOBAL_SETTINGS_FILE"
  printf 'key,docker_options\n' >"$BACKEND_DOCKER_OPTS_FILE"
  printf '2\n' >"$CONFIG_DIR/state_schema_version"
  printf 'domain\na.example.com\nc.example.com\n' >"$CONFIG_DIR/domain_inventory.csv"
  state_backend_ports_row_backend a.example.com 172.20.0.7:8080 dockistrate-net >>"$BACKEND_PORTS_FILE"
  state_backend_ports_row_port a.example.com 38180 8080 http none no off '' >>"$BACKEND_PORTS_FILE"
  printf '# Serving configuration must stay byte-identical.\n' >"$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
  for part in config runtime/applied; do
    printf 'key,value\nschema_version,2\nrole,backend\n' >"$DOMAINS_DIR/a.example.com/$part/domain.csv"
    printf 'key,value\nimage,nginx:alpine\ncontainer_port,8080\nnetwork,dockistrate-net\nstate,running\n' >"$DOMAINS_DIR/a.example.com/$part/backend.csv"
    printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id\n38180,8080,http,,\n' >"$DOMAINS_DIR/a.example.com/$part/ports.csv"
    printf 'key,value\nhttp_version,http1.1\n' >"$DOMAINS_DIR/a.example.com/$part/settings.csv"
  done
  printf 'key,value\nhttp_version,http1.0\n' >"$DOMAINS_DIR/a.example.com/config/settings.csv"
  printf 'key,value\nschema_version,2\nrole,certificate-only\n' >"$DOMAINS_DIR/b.example.com/config/domain.csv"
  printf 'key,value\nhttp_version,unfinished-invalid-value\n' >"$DOMAINS_DIR/b.example.com/config/settings.csv"
  printf 'key,value\nschema_version,2\nrole,certificate-only\n' >"$DOMAINS_DIR/c.example.com/runtime/applied/domain.csv"
  cp "$DOMAINS_DIR/a.example.com/runtime/applied/backend.csv" "$DOMAINS_DIR/a.example.com/runtime/backend.csv"
  id="$(printf '%064d' 1)"; token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  printf 'domain,container_id,ownership_token\na.example.com,%s,%s\n' "$id" "$token" >"$CONFIG_DIR/backend_identity.csv"
  printf 'key,value\ncontainer_id,%s\nownership_token,%s\nimage,nginx:alpine\nimage_id,sha256:saved\nstate,running\nnetwork,dockistrate-net\naddress,172.20.0.7\n' "$id" "$token" >"$DOMAINS_DIR/a.example.com/runtime/observed.csv"
  printf 'key,value\nprovider,custom\nport_suffix,443\ndeclared,no\nspecification,saved-fingerprint\nsource_ref,custom/live/a.example.com_443\n' >"$DOMAINS_DIR/a.example.com/certs/retained/certificate.csv"
)
fingerprint >"$TEST_WORK/before"
run_cli migrate-state --dry-run
fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/before" "$TEST_WORK/after" || fail_test 'Schema-2 dry-run changed state'
[ ! -s "$DOCKER_TEST_LOG" ] || fail_test 'Schema-2 dry-run queried Docker'

# Interrupt ordinary completion after all data and the new schema marker were
# written. Rollback must restore the old globals and both separate snapshots.
sed 's/^function _domain_config_mark_cache() {/function _test_original_mark_cache() {/' \
  "$TEST_WORK/lib/domain_config/cache.sh" >"$TEST_WORK/cache.sh"
mv "$TEST_WORK/cache.sh" "$TEST_WORK/lib/domain_config/cache.sh"
cat >"$TEST_WORK/lib/domain_config/zz_schema3_failure.sh" <<'EOF'
# shellcheck shell=bash
function _domain_config_mark_cache() {
  if [ "${DOMAIN_CONFIG_MIGRATING:-false}" = true ] && [ -f "$BASE_DIR/fail-migration" ]; then
    if [ -f "$BASE_DIR/edit-migration" ]; then
      _domain_csv_set "$STATE_DIR/domains/a.example.com/config/settings.csv" http_version http2 || return 1
    fi
    printf 'marker-written\n' >"$BASE_DIR/failure-reached"
    return 1
  fi
  _test_original_mark_cache "$@"
}
EOF
: >"$TEST_WORK/fail-migration"
if "$BASH" "$BIN" migrate-state >"$TEST_WORK/output" 2>&1; then fail_test 'Injected migration failure succeeded'; fi
[ -f "$TEST_WORK/failure-reached" ] || fail_test 'Migration failed before the injected checkpoint'
grep -Fq 'Rolled back.' "$TEST_WORK/output" || fail_test 'Failed migration did not recover immediately'
fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/before" "$TEST_WORK/after" || fail_test 'Failed migration lost schema-2 data or pending edits'
# A later editor write survives rollback as a wide draft beside the restored
# schema-2 applied snapshot. Retrying must convert that mixed layout losslessly.
: >"$TEST_WORK/edit-migration"
if "$BASH" "$BIN" migrate-state >"$TEST_WORK/output" 2>&1; then fail_test 'Concurrent edit failure succeeded'; fi
grep -Fq 'Rolled back.' "$TEST_WORK/output" || fail_test 'Concurrent edit failure did not recover'
[ "$(cat "$TEST_WORK/state/config/state_schema_version")" = 2 ] || fail_test 'Concurrent edit failure retained the new schema marker'
grep -qx 'schema_version,role,target' "$TEST_WORK/state/domains/a.example.com/config/domain.csv" || fail_test 'Rollback discarded the edited wide draft'
grep -qx 'key,value' "$TEST_WORK/state/domains/a.example.com/runtime/applied/domain.csv" || fail_test 'Rollback did not restore the old applied snapshot'
rm "$TEST_WORK/edit-migration"
rm "$TEST_WORK/fail-migration"
: >"$DOCKER_TEST_LOG"
run_cli migrate-state
[ "$(cat "$TEST_WORK/state/config/state_schema_version")" = 5 ] || fail_test 'Migration omitted schema 5'
[ ! -s "$DOCKER_TEST_LOG" ] || fail_test 'Schema-2 migration queried or changed Docker'

# Read the new records independently of implementation helpers.
python3 - "$TEST_WORK/state" <<'PY'
import csv, pathlib, sys
state=pathlib.Path(sys.argv[1]); domains=state/'domains'
def record(path):
    with path.open() as stream: result=list(csv.DictReader(stream))
    assert len(result)==1, path
    return result[0]
assert record(domains/'a.example.com/config/settings.csv')['http_version']=='http2'
assert record(domains/'a.example.com/runtime/applied/settings.csv')['http_version']=='http1.1'
assert record(domains/'b.example.com/config/settings.csv')['http_version']=='unfinished-invalid-value'
assert not (domains/'b.example.com/runtime/applied').exists()
assert not (domains/'c.example.com/config').exists()
assert record(domains/'c.example.com/runtime/applied/domain.csv')['role']=='certificate-only'
observed=record(domains/'a.example.com/runtime/observed.csv')
assert observed['container_id']=='0'*63+'1' and observed['address']=='172.20.0.7'
certificate=record(domains/'a.example.com/certs/retained/certificate.csv')
assert certificate['declared']=='no' and certificate['specification']=='saved-fingerprint'
assert certificate['source_ref']=='custom/live/a.example.com_443'
shared=record(state/'config/global_settings.csv')
assert shared['http_version']=='http1.1' and shared['EXAMPLE_EXTENSION']=='preserve-me'
assert (state/'config/nginx_conf/conf.d/backends.conf').read_text()=='# Serving configuration must stay byte-identical.\n'
PY
run_cli migrate-state
grep -Fq 'already uses schema 5' "$TEST_WORK/output" || fail_test 'Migration is not idempotent'
printf '[PASS] schema-2 migration preserves pending and missing drafts, identities, metadata and rollback\n'
