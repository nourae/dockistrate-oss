#!/usr/bin/env bash
# Fixture settings are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-schema4-lifecycle.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
mkdir "$TEST_WORK/bin"
cat >"$TEST_WORK/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
# Fixture settings are consumed by sourced production modules.
# shellcheck disable=SC2034
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
  source "$TEST_WORK/lib/domain_config.sh"
  STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"
  _domain_config_bind_config "$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR/nginx_conf/conf.d" "$DOMAINS_DIR/example.com/config" "$DOMAINS_DIR/example.com/runtime/applied" \
    "$DOMAINS_DIR/alias.example.com/config" "$DOMAINS_DIR/alias.example.com/runtime/applied" "$DOMAINS_DIR/example.com/certs/tls"
  state_security_rules_use_schema 3
  state_csv_ensure_all_state_files
  ENABLE_AUTO_BACKUPS=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '3\n' >"$CONFIG_DIR/state_schema_version"
  printf 'domain\nexample.com\nalias.example.com\n' >"$CONFIG_DIR/domain_inventory.csv"
  state_backend_ports_row_backend example.com 172.20.0.7:8080 dockistrate-net >>"$BACKEND_PORTS_FILE"
  state_backend_ports_row_port example.com 38180 8080 http none no off '' >>"$BACKEND_PORTS_FILE"
  printf '# Keep the serving projection unchanged.\n' >"$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
  for part in config runtime/applied; do
    directory="$DOMAINS_DIR/example.com/$part"
    printf 'schema_version,role,target\n3,backend,\n' >"$directory/domain.csv"
    printf 'image,container_port,network,state\nnginx:alpine,8080,dockistrate-net,running\n' >"$directory/backend.csv"
    # Historical named records with reordered headers, quotes and CRLF.
    printf 'protocol,listen_port,certificate_id,upstream_port,certificate_owner\r\nhttp,"38180",,8080,\r\nhttps,38443,tls,8080,example.com\r\n' >"$directory/ports.csv"
    printf 'alt_svc,http3_enabled,redirect_code,redirect_enabled,websocket,protocol,listen_port\n"auto",off,,off,yes,http,38180\n"auto",on,,off,no,https,38443\n' >"$directory/port_options.csv"
    printf 'port_suffix,provider,certificate_id\n443,selfsigned,tls\n' >"$directory/certificates.csv"
    printf 'source_privkey,certificate_id,source_fullchain\n,tls,\n' >"$directory/certificate_options.csv"
    printf 'schema_version,role,target\n3,alias,example.com\n' >"$DOMAINS_DIR/alias.example.com/$part/domain.csv"
  done
  printf 'listen_port,protocol,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n38180,http,no,off,,off,auto\n38443,https,no,off,,on,auto\n' >"$DOMAINS_DIR/example.com/config/port_options.csv"
  printf 'retained certificate bytes\n' >"$DOMAINS_DIR/example.com/certs/tls/fullchain.pem"
  printf 'retained private bytes\n' >"$DOMAINS_DIR/example.com/certs/tls/privkey.pem"
)
# Keep an actual format-3 backup for the independent restore conversion below.
mkdir -p "$TEST_WORK/format3/shared"
cp -R "$TEST_WORK/state/config" "$TEST_WORK/state/domains" "$TEST_WORK/format3/"
printf 'format_version,state_schema_version\n3,3\n' >"$TEST_WORK/format3/backup_manifest.csv"
fingerprint >"$TEST_WORK/before"
run_cli migrate-state --dry-run
fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/before" "$TEST_WORK/after" || fail_test 'Schema-3 preview changed persisted state'
grep -Fq 'schema 3 -> 5' "$TEST_WORK/output" || fail_test 'Preview omitted source and target schema'
[ ! -s "$DOCKER_TEST_LOG" ] || fail_test 'Storage migration inspected Docker'
# Orphan options cannot silently disappear during migration.
printf '39999,http,yes,off,,off,auto\n' >>"$TEST_WORK/state/domains/example.com/config/port_options.csv"
fingerprint >"$TEST_WORK/orphan-before"
if "$BASH" "$BIN" migrate-state >"$TEST_WORK/output" 2>&1; then fail_test 'Migration accepted an orphan option record'; fi
grep -Fq 'no matching ports.csv record' "$TEST_WORK/output" || fail_test 'Orphan record failure was unclear'
fingerprint >"$TEST_WORK/after"
cmp -s "$TEST_WORK/orphan-before" "$TEST_WORK/after" || fail_test 'Failed preflight changed persisted state'
cp "$TEST_WORK/format3/domains/example.com/config/port_options.csv" "$TEST_WORK/state/domains/example.com/config/port_options.csv"
run_cli migrate-state
[ "$(cat "$TEST_WORK/state/config/state_schema_version")" = 5 ] || fail_test 'Migration did not publish schema5'
[ ! -s "$DOCKER_TEST_LOG" ] || fail_test 'Storage migration changed runtime'
python3 - "$TEST_WORK" <<'PY'
import csv, pathlib, sys
root=pathlib.Path(sys.argv[1]); live=root/'state'; old=root/'format3'
def records(path):
    with path.open() as stream: return list(csv.DictReader(stream))
for part in ('config', 'runtime/applied'):
    directory=live/'domains/example.com'/part
    ports=records(directory/'ports.csv')
    assert len(ports[0])==10 and len(ports)==2
    assert ports[0]['websocket']==('no' if part=='config' else 'yes')
    assert ports[1]['http3_enabled']=='on'
    assert ports[1]['certificate_owner']=='example.com' and ports[1]['certificate_id']=='tls'
    certificates=records(directory/'certificates.csv')
    assert len(certificates[0])==5 and certificates[0]['provider']=='selfsigned'
    assert not (directory/'port_options.csv').exists()
    assert not (directory/'certificate_options.csv').exists()
    assert records(directory/'domain.csv')[0]['schema_version']=='5'
    assert records(live/'domains/alias.example.com'/part/'domain.csv')[0]['target']=='example.com'
for relative in ('config/nginx_conf/conf.d/backends.conf', 'domains/example.com/certs/tls/fullchain.pem', 'domains/example.com/certs/tls/privkey.pem'):
    assert (live/relative).read_bytes()==(old/relative).read_bytes()
PY
run_cli migrate-state
run_cli validate-domain-config --all
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  STATE_DIR="$TEST_WORK/state"; _domain_config_bind_config "$STATE_DIR/config"
  _domain_backup_manifest_validate "$TEST_WORK/format3" || fail_test 'Historical format-3 manifest rejected'
  cp -R "$TEST_WORK/format3" "$TEST_WORK/prepared"
  _domain_restore_convert_legacy_domains "$TEST_WORK/prepared" 3 || fail_test 'Format-3 restore conversion failed'
  cmp "$TEST_WORK/prepared/domains/example.com/config/ports.csv" "$STATE_DIR/domains/example.com/config/ports.csv" || fail_test 'Migration and restore differ'
  cmp "$TEST_WORK/prepared/domains/example.com/runtime/applied/ports.csv" "$STATE_DIR/domains/example.com/runtime/applied/ports.csv" || fail_test 'Restore lost applied options'
  # Interrupted schema-3 transactions can render their restored applied
  # listener records before migration. That scoped read must keep every option.
  _dc_domain=example.com
  _dc_config="$TEST_WORK/format3/domains/example.com/runtime/applied"
  _dc_output="$TEST_WORK/compiled3"; mkdir -p "$_dc_output"
  : >"$_dc_output/backend_ports.csv"
  DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3 DOMAIN_CONFIG_LEGACY_RECOVERY=true _domain_csv_read "$_dc_config/ports.csv" _domain_config_compile_port
  _dc_config="$STATE_DIR/domains/example.com/runtime/applied"
  _dc_output="$TEST_WORK/compiled4"; mkdir -p "$_dc_output"
  : >"$_dc_output/backend_ports.csv"
  _domain_csv_read "$_dc_config/ports.csv" _domain_config_compile_port
  cmp "$TEST_WORK/compiled3/backend_ports.csv" "$TEST_WORK/compiled4/backend_ports.csv" || fail_test 'Legacy recovery changed listener behavior'
  # Invalid draft values remain editable after structural conversion.
  old="$TEST_WORK/invalid"; cp -R "$TEST_WORK/format3/domains/example.com/config" "$old"
  printf 'listen_port,protocol,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n38180,http,unfinished,off,,off,auto\n' >"$old/port_options.csv"
  _domain_csv_convert_directory 3 "$old" "$TEST_WORK/invalid-converted" || fail_test 'Invalid draft values were discarded'
  grep -Fq unfinished "$TEST_WORK/invalid-converted/ports.csv" || fail_test 'Conversion lost unfinished option value'
  printf '38180,http,yes,off,,off,auto\n' >>"$old/port_options.csv"
  if _domain_csv_convert_directory 3 "$old" "$TEST_WORK/duplicate" >"$TEST_WORK/output" 2>&1; then fail_test 'Duplicate options accepted'; fi
)
printf '[PASS] schema-3 storage and backup conversion merge listener/certificate records without activating drafts\n'
