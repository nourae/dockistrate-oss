#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-remove-alias-policy.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true
BIN="$TEST_WORK/dockistrate.sh"
DOMAINS="$TEST_WORK/state/domains"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function run_cli() {
  "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "command failed: $*"; }
}

run_cli init-domain-config example.com
python3 - "$DOMAINS" <<'PY'
import csv,pathlib,sys
root=pathlib.Path(sys.argv[1])
def write(domain,name,header,rows):
    directory=root/domain/'config'; directory.mkdir(parents=True,exist_ok=True)
    with (directory/name).open('w',newline='') as output:
        writer=csv.writer(output,lineterminator='\n'); writer.writerow(header.split(',')); writer.writerows(rows)
hosts=[('example.com','backend',''),('alias.example.com','alias','example.com'),
       ('dedicated.example.com','dedicated','example.com'),('other.test','backend',''),
       ('alias.other.test','alias','other.test'),('standalone.test','dedicated','other.test')]
for order,(domain,role,target) in enumerate(hosts,1):
    write(domain,'domain.csv','schema_version,role,target',[[5,role,target]])
    if role=='backend':
        write(domain,'backend.csv','image,container_port,network,state',
              [['nginx:alpine',8080,'dockistrate-net','running']])
    action=['require','block','allow','require','block','block'][order-1]
    write(domain,'security_rules.csv','rule_id,order,enabled,action,mode,status_code,reason,source_location',
          [[f'rule-{order}',order,1,action,'single',403,'-', 'auto']])
    write(domain,'security_conditions.csv','rule_id,condition_order,selector,name,operator,value',
          [[f'rule-{order}',1,'header','X-Test','equals','blocked']])
    write(domain,'acl.csv','rule_id,order,enabled,scope,action,ip_value,status_code',
          [[f'acl-{order}',order,1,'l7','deny',f'192.0.2.{order}',403]])
    write(domain,'headers.csv','header_type,header_name,header_value',[['response','X-Owner',domain]])
    write(domain,'settings.csv','http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status',
          [['','','','allow',403,429]])
    if domain in ['dedicated.example.com','standalone.test','other.test']:
        write(domain,'mtls.csv','enabled,directory',[['yes',str(root/domain/'mtls')]])
ports='listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc'
write('example.com','ports.csv',ports,[[19080,8080,'http','','','no','off','','off','auto']])
write('other.test','ports.csv',ports,[[19443,8080,'https','alias.example.com','selfsigned-19443','no','off','','off','auto']])
write('alias.example.com','certificates.csv','certificate_id,provider,port_suffix,source_fullchain,source_privkey',
      [['selfsigned-19443','selfsigned',19443,'','']])
PY
run_cli apply-domain-config --all
# Disabling mTLS intentionally leaves owned material without an active mapping.
# Removal must still clean that material, while preserving the other owners.
cp -R "$DOMAINS/dedicated.example.com/mtls" "$DOMAINS/example.com/mtls"
mkdir "$TEST_WORK/before"
for domain in example.com alias.example.com dedicated.example.com other.test alias.other.test standalone.test; do
  mkdir -p "$TEST_WORK/before/$domain/runtime"
  cp -R "$DOMAINS/$domain/config" "$TEST_WORK/before/$domain/"
  cp -R "$DOMAINS/$domain/runtime/applied" "$TEST_WORK/before/$domain/runtime/"
  [ ! -d "$DOMAINS/$domain/mtls" ] || cp -R "$DOMAINS/$domain/mtls" "$TEST_WORK/before/$domain/"
done
cp -R "$TEST_WORK/state/config/nginx_conf" "$TEST_WORK/nginx.before"
cp "$DOMAINS/alias.example.com/certs/selfsigned-19443/fullchain.pem" "$TEST_WORK/certificate.before"
cp "$DOMAINS/alias.example.com/certs/selfsigned-19443/privkey.pem" "$TEST_WORK/key.before"
cp "$TEST_WORK/state/config/backend_aliases.csv" "$TEST_WORK/aliases.before"
cp "$TEST_WORK/state/config/security_rules.csv" "$TEST_WORK/rules.before"
cp "$TEST_WORK/state/config/security_ip_rules.csv" "$TEST_WORK/acl.before"

# Fail after real candidate validation, deferred rendering, and publication of
# editable/applied records. The outer transaction must restore the complete policy.
cat >>"$TEST_WORK/lib/domain_config/generated.sh" <<'HOOK'
eval "$(declare -f _domain_config_publish_generated | sed '1s/_domain_config_publish_generated/_test_publish_generated/')"
function _domain_config_publish_generated() {
  if [ "${FAIL_ALIAS_REMOVAL_PUBLICATION:-false}" = true ]; then
    printf 'reached\n' >"$BASE_DIR/failure-reached"
    return 1
  fi
  _test_publish_generated "$@"
}
HOOK
if FAIL_ALIAS_REMOVAL_PUBLICATION=true "$BIN" remove-backend --yes example.com >"$TEST_WORK/output" 2>&1; then
  fail_test 'Publication failure committed backend removal'
fi
[ -f "$TEST_WORK/failure-reached" ] || { cat "$TEST_WORK/output" >&2; fail_test 'Removal failed before final publication'; }
for domain in example.com alias.example.com dedicated.example.com other.test alias.other.test standalone.test; do
  diff -r "$TEST_WORK/before/$domain/config" "$DOMAINS/$domain/config" || fail_test 'Rollback changed editable policy'
  diff -r "$TEST_WORK/before/$domain/runtime/applied" "$DOMAINS/$domain/runtime/applied" || fail_test 'Rollback changed applied policy'
  [ ! -d "$TEST_WORK/before/$domain/mtls" ] || diff -r "$TEST_WORK/before/$domain/mtls" "$DOMAINS/$domain/mtls" || fail_test 'Rollback lost owned mTLS material'
done
diff -r "$TEST_WORK/nginx.before" "$TEST_WORK/state/config/nginx_conf" || fail_test 'Rollback lost generated includes'
cmp -s "$TEST_WORK/aliases.before" "$TEST_WORK/state/config/backend_aliases.csv" || fail_test 'Rollback lost hostname maps'
cmp -s "$TEST_WORK/rules.before" "$TEST_WORK/state/config/security_rules.csv" || fail_test 'Rollback lost security rules'
cmp -s "$TEST_WORK/acl.before" "$TEST_WORK/state/config/security_ip_rules.csv" || fail_test 'Rollback lost ACLs'

run_cli remove-backend --yes example.com
run_cli validate-domain-config --all
python3 - "$TEST_WORK" <<'PY'
import csv,pathlib,sys
root=pathlib.Path(sys.argv[1]); state=root/'state'; domains=state/'domains'
def records(file):
    with file.open() as source: return list(csv.DictReader(source))
removed={'example.com','alias.example.com','dedicated.example.com'}
for name in ['security_rules.csv','security_ip_rules.csv']:
    rows=records(state/'config'/name)
    assert {row['domain'] for row in rows}=={'other.test','alias.other.test','standalone.test'},name
for name in ['backend_headers.csv','backend_acl_policies.csv','backend_acl_statuses.csv','backend_security_rule_statuses.csv']:
    assert not any(row['domain'] in removed for row in records(state/'config'/name)),name
assert records(state/'config'/'backend_aliases.csv')==[
    {'record_type':'alias','hostname':'alias.other.test','target_domain':'other.test'},
    {'record_type':'dedicated','hostname':'standalone.test','target_domain':'other.test'}]
for domain in ['example.com','dedicated.example.com']:
    assert not (domains/domain/'config').exists(),domain
    assert not (domains/domain/'runtime'/'applied').exists(),domain
for domain in ['other.test','alias.other.test','standalone.test']:
    for part in ['config','runtime/applied']:
        before=root/'before'/domain/part; after=domains/domain/part
        assert {p.name:p.read_bytes() for p in before.iterdir()}=={p.name:p.read_bytes() for p in after.iterdir()},(domain,part)
for domain in ['example.com','dedicated.example.com']:
    assert not (domains/domain/'mtls').exists(),f'Owned mTLS survived backend removal: {domain}'
for domain in removed:
    for context in ['conf.d','stream_conf']:
        assert not (state/'config/nginx_conf'/context/'security_ip'/f'{domain}.inc').exists(),(domain,context)
    for name in ['acl-http.inc','acl-stream.inc']:
        assert not (domains/domain/'generated/nginx'/name).exists(),(domain,name)
for domain in ['other.test','standalone.test']:
    before=root/'before'/domain/'mtls'; after=domains/domain/'mtls'
    assert {str(p.relative_to(before)):p.read_bytes() for p in before.rglob('*') if p.is_file()}=={str(p.relative_to(after)):p.read_bytes() for p in after.rglob('*') if p.is_file()},domain
# The removed alias still owns a certificate consumed by the surviving backend.
for part in ['config','runtime/applied']:
    config=domains/'alias.example.com'/part
    assert records(config/'domain.csv')[0]['role']=='certificate-only'
    for name in ['acl.csv','security_rules.csv','security_conditions.csv','headers.csv']:
        assert not records(config/name),name
PY
cmp -s "$TEST_WORK/certificate.before" "$DOMAINS/alias.example.com/certs/selfsigned-19443/fullchain.pem" || fail_test 'Shared certificate changed'
cmp -s "$TEST_WORK/key.before" "$DOMAINS/alias.example.com/certs/selfsigned-19443/privkey.pem" || fail_test 'Shared private key changed'
# Standalone dedicated-host removal uses the same guarded cleanup and rollback.
cp "$TEST_WORK/state/config/backend_aliases.csv" "$TEST_WORK/standalone-aliases.before"
rm -f "$TEST_WORK/failure-reached"
cp -R "$DOMAINS/standalone.test/generated" "$TEST_WORK/standalone-generated.before"
if FAIL_ALIAS_REMOVAL_PUBLICATION=true "$BIN" remove-dedicated-host standalone.test >"$TEST_WORK/output" 2>&1; then
  fail_test 'Publication failure committed dedicated-host removal'
fi
[ -f "$TEST_WORK/failure-reached" ] || { cat "$TEST_WORK/output" >&2; fail_test 'Dedicated removal failed before final publication'; }
diff -r "$TEST_WORK/before/standalone.test/mtls" "$DOMAINS/standalone.test/mtls" || fail_test 'Dedicated rollback lost mTLS material'
diff -r "$TEST_WORK/standalone-generated.before" "$DOMAINS/standalone.test/generated" || fail_test 'Dedicated rollback lost generated mirrors'
cmp -s "$TEST_WORK/standalone-aliases.before" "$TEST_WORK/state/config/backend_aliases.csv" || fail_test 'Dedicated rollback lost its mapping'
run_cli remove-dedicated-host standalone.test
[ ! -e "$DOMAINS/standalone.test/mtls" ] || fail_test 'Standalone removal retained owned mTLS'
for context in conf.d stream_conf; do
  [ ! -e "$TEST_WORK/state/config/nginx_conf/$context/security_ip/standalone.test.inc" ] || fail_test 'Standalone removal retained ACL include'
done
diff -r "$TEST_WORK/before/other.test/mtls" "$DOMAINS/other.test/mtls" || fail_test 'Removal changed another authority'
cmp -s "$TEST_WORK/key.before" "$DOMAINS/alias.example.com/certs/selfsigned-19443/privkey.pem" || fail_test 'Dedicated removal changed shared private key'
printf '[PASS] Backend/dedicated removal cleans policies, owned mTLS and ACL includes; preserves shared certificates and rolls back failures\n'
