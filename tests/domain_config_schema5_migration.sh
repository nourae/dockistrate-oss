#!/usr/bin/env bash
# Fixture settings are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-schema5-migration.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
TEST_COMPLETE=false
trap 'test_status=$?; rm -rf "$TEST_WORK"; if [ "$TEST_COMPLETE" != true ] && [ "$test_status" -eq 0 ]; then test_status=1; fi; exit "$test_status"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
mkdir "$TEST_WORK/bin"
cat >"$TEST_WORK/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_TEST_LOG"
exit 99
DOCKER
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
  source "$TEST_WORK/lib/security_rules.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"
  _domain_config_bind_config "$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR/nginx_conf/conf.d" "$DOMAINS_DIR/example.com/config" "$DOMAINS_DIR/example.com/runtime/applied"
  state_security_rules_use_schema 4
  state_csv_ensure_all_state_files
  ENABLE_AUTO_BACKUPS=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '4\n' >"$CONFIG_DIR/state_schema_version"
  printf 'domain\nexample.com\n' >"$CONFIG_DIR/domain_inventory.csv"
  state_backend_ports_row_backend example.com 172.20.0.7:8080 dockistrate-net >>"$BACKEND_PORTS_FILE"
  state_backend_ports_row_port example.com 38180 8080 http none no off '' >>"$BACKEND_PORTS_FILE"
  _sr_write_db_line 1 example.com single 403 1 'Required, token' auto header X-Token equals accepted >>"$SECURITY_RULES_FILE"
  printf '# The serving projection stays untouched.\n' >"$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
  for part in config runtime/applied; do
    directory="$DOMAINS_DIR/example.com/$part"
    printf 'schema_version,role,target\n4,backend,\n' >"$directory/domain.csv"
    printf 'image,container_port,network,state\nnginx:alpine,8080,dockistrate-net,running\n' >"$directory/backend.csv"
    printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n38180,8080,http,,,no,off,,off,auto\n' >"$directory/ports.csv"
    printf 'source_location,rule_id,mode,order,reason,status_code,enabled\r\nauto,rule-9,single,9,"Required, token",403,1\r\n' >"$directory/security_rules.csv"
    printf 'rule_id,condition_order,selector,name,operator,value\nrule-9,1,header,X-Token,equals,accepted\n' >"$directory/security_conditions.csv"
  done
  # Desired bytes are intentionally different and include opaque saved work.
  printf 'rule_id,condition_order,selector,name,operator,value\nrule-9,1,header,X-Token,equals,draft-value\n' >"$DOMAINS_DIR/example.com/config/security_conditions.csv"
  mkdir -p "$DOMAINS_DIR/example.com/config/notes/empty"
  printf 'Unfinished policy notes\n' >"$DOMAINS_DIR/example.com/config/notes/.todo"
)
mkdir -p "$TEST_WORK/format4/shared"
cp -R "$TEST_WORK/state/config" "$TEST_WORK/state/domains" "$TEST_WORK/format4/"
printf 'format_version,state_schema_version\n4,4\n' >"$TEST_WORK/format4/backup_manifest.csv"
fingerprint >"$TEST_WORK/before"
run_cli migrate-state --dry-run
fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/before" "$TEST_WORK/after" || fail_test 'Preview changed persisted state'
grep -Fq 'schema 4 -> 5' "$TEST_WORK/output" || fail_test 'Preview omitted schema transition'
[ ! -s "$DOCKER_TEST_LOG" ] || fail_test 'Preview inspected Docker'

# Invalid accepted rules fail before publication; drafts cannot conceal them.
printf 'rule-9,1,header,X-Token,equals,duplicate\n' >>"$TEST_WORK/state/domains/example.com/runtime/applied/security_conditions.csv"
fingerprint >"$TEST_WORK/invalid-before"
if "$BASH" "$BIN" migrate-state >"$TEST_WORK/output" 2>&1; then fail_test 'Migration accepted duplicate applied conditions'; fi
fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/invalid-before" "$TEST_WORK/after" || fail_test 'Failed preflight changed persisted state'
cp "$TEST_WORK/format4/domains/example.com/runtime/applied/security_conditions.csv" "$TEST_WORK/state/domains/example.com/runtime/applied/security_conditions.csv"
run_cli migrate-state
[ "$(cat "$TEST_WORK/state/config/state_schema_version")" = 5 ] || fail_test 'Migration did not publish schema5'
[ ! -s "$DOCKER_TEST_LOG" ] || fail_test 'Storage migration changed runtime'
python3 - "$TEST_WORK" <<'PY'
import csv, pathlib, sys
root=pathlib.Path(sys.argv[1]); live=root/'state'; old=root/'format4'
def records(path):
    with path.open() as stream: return list(csv.DictReader(stream))
for part in ('config', 'runtime/applied'):
    directory=live/'domains/example.com'/part
    rule=records(directory/'security_rules.csv')[0]
    assert list(rule)==['rule_id','order','enabled','action','mode','status_code','reason','source_location']
    assert rule['rule_id']=='rule-9' and rule['order']=='9' and rule['action']=='require'
    assert rule['reason']=='Required, token' and rule['mode']=='single'
    assert records(directory/'domain.csv')[0]['schema_version']=='5'
    assert records(directory/'security_conditions.csv')[0]['value']==('draft-value' if part=='config' else 'accepted')
rows=records(live/'config/security_rules.csv')
assert len(rows[0])==48 and rows[0]['action']=='require'
assert rows[0]['value_1']=='accepted'
for relative in ('config/nginx_conf/conf.d/backends.conf', 'domains/example.com/config/notes/.todo'):
    assert (live/relative).read_bytes()==(old/relative).read_bytes()
assert (live/'domains/example.com/config/notes/empty').is_dir()
PY
run_cli migrate-state
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/backends.sh"
  source "$TEST_WORK/lib/backups.sh"
  source "$TEST_WORK/lib/security_rules.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  STATE_DIR="$TEST_WORK/state"; _domain_config_bind_config "$STATE_DIR/config"
  _domain_backup_manifest_validate "$TEST_WORK/format4" || fail_test 'Format4 manifest rejected'
  cp -R "$TEST_WORK/format4" "$TEST_WORK/prepared"
  _domain_restore_convert_legacy_domains "$TEST_WORK/prepared" 4 || fail_test 'Format4 restore conversion failed'
  cmp "$TEST_WORK/prepared/domains/example.com/config/security_rules.csv" "$STATE_DIR/domains/example.com/config/security_rules.csv" || fail_test 'Migration and restore actions differ'
  cmp "$TEST_WORK/prepared/domains/example.com/config/notes/.todo" "$STATE_DIR/domains/example.com/config/notes/.todo" || fail_test 'Restore conversion discarded nested drafts'
  cmp "$TEST_WORK/prepared/domains/example.com/runtime/applied/security_conditions.csv" "$TEST_WORK/format4/domains/example.com/runtime/applied/security_conditions.csv" || fail_test 'Restore consumed pending draft conditions'
  _domain_config_convert_shared_config "$TEST_WORK/format4/config" "$TEST_WORK/converted-shared" || fail_test 'Shared restore conversion failed'
  cmp "$TEST_WORK/converted-shared/security_rules.csv" "$CONFIG_DIR/security_rules.csv" || fail_test 'Restore aggregate conversion differs'
  # Previously converted drafts retained by interrupted-migration recovery keep
  # their explicit action on retry; legacy rows still acquire require.
  source="$TEST_WORK/retry"; cp -R "$TEST_WORK/format4/domains/example.com/runtime/applied" "$source"
  printf 'schema_version,role,target\n5,backend,\n' >"$source/domain.csv"
  printf 'rule_id,order,enabled,action,mode,status_code,reason,source_location\nrule-9,9,1,block,single,403,-,auto\n' >"$source/security_rules.csv"
  for version in 2 3 4; do
    _domain_csv_convert_directory "$version" "$source" "$TEST_WORK/retry-$version" || fail_test "Retry conversion failed for schema$version"
    grep -q 'rule-9,9,1,block,single' "$TEST_WORK/retry-$version/security_rules.csv" || fail_test 'Retry reset an explicit draft action'
  done
)
TEST_COMPLETE=true
printf '[PASS] Schema5 migration, aggregate conversion and format4 draft preservation\n'
