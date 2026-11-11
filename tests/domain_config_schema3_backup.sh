#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
for module in logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config; do
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-schema3-backup.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/live"; TMP_DIR="$STATE_DIR/tmp"; BACKUP_DIR="$STATE_DIR/backups"; CERTS_DIR="$STATE_DIR/certs"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR"
printf '5\n' >"$CONFIG_DIR/state_schema_version"
export SKIP_DOCKER_CHECKS=true
source_backup="$TEST_WORK/format2"
result="$TEST_WORK/converted"
mkdir -p "$source_backup/config" "$source_backup/shared" "$source_backup/domains/example.com/runtime/applied"
mkdir -p "$source_backup/domains/example.com/config" "$source_backup/domains/example.com/certs/upload"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function check_dependencies() { :; }
function docker() { fail_test "Restore conversion must not call Docker: $*"; }
function _domain_restore_activate() {
  [ "$3" = false ] || return 1
  cp -R "$2" "$result"
}
function transaction_is_active() { return 0; }
function add_cert() { fail_test 'Existing custom material should be reused without issuing or importing'; }
function snapshot_source() {
  (cd "$source_backup" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do printf '%s\n' "$file"; cksum <"$file"; done)
}

printf 'key,value\nformat_version,2\nstate_schema_version,2\n' >"$source_backup/backup_manifest.csv"
printf '2\n' >"$source_backup/config/state_schema_version"
printf 'setting_key,setting_value\nHTTP_VERSION,http1.1\nEXAMPLE_EXTENSION,preserved\n' >"$source_backup/config/global_settings.csv"
printf 'key,docker_options\n' >"$source_backup/config/backend_docker_opts.csv"
printf 'domain\nexample.com\n' >"$source_backup/config/domain_inventory.csv"
for directory in "$source_backup/domains/example.com/config" "$source_backup/domains/example.com/runtime/applied"; do
  printf 'key,value\nschema_version,2\nrole,backend\ntarget,\n' >"$directory/domain.csv"
  printf 'key,value\nhttp_version,http1.1\n' >"$directory/settings.csv"
  printf 'key,value\nimage,nginx:alpine\ncontainer_port,8080\nnetwork,dockistrate-net\nstate,stopped\n' >"$directory/backend.csv"
  printf 'provider,port_suffix,certificate_id\ncustom,443,upload\n' >"$directory/certificates.csv"
  printf 'certificate_id,key,value\nupload,source_fullchain,/missing/import/fullchain.pem\nupload,source_privkey,/missing/import/privkey.pem\n' >"$directory/certificate_options.csv"
done
printf 'key,value\nhttp_version,http1.0\n' >"$source_backup/domains/example.com/config/settings.csv"
material="$source_backup/domains/example.com/certs/upload"
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$material/privkey.pem" -out "$material/fullchain.pem" -subj /CN=example.com >/dev/null 2>&1
chmod 600 "$material/privkey.pem"
specification="$(_domain_cert_fingerprint upload custom 443 /missing/import/fullchain.pem /missing/import/privkey.pem)"
{
  printf 'key,value\nprovider,custom\nport_suffix,443\ndeclared,yes\n'
  csv_join_row specification "$specification"
  printf 'source_ref,custom/live/example.com_443\n'
} >"$material/certificate.csv"
printf 'key,value\nimage,nginx:alpine\ncontainer_port,8080\nnetwork,dockistrate-net\nstate,stopped\n' >"$source_backup/domains/example.com/runtime/backend.csv"
printf 'key,value\ncontainer_id,%064d\nownership_token,%032d\nimage,nginx:alpine\nimage_id,sha256:saved\nstate,stopped\nnetwork,dockistrate-net\naddress,172.20.0.3\n' 1 1 >"$source_backup/domains/example.com/runtime/observed.csv"
# Reordered internal table fields still reconstruct only validated issuer links.
mkdir -p "$source_backup/shared/acme/live/example.com" "$source_backup/shared/acme/archive/example.com"
printf 'issuer fixture material\n' >"$source_backup/shared/acme/live/example.com/fullchain.pem"
cp "$source_backup/shared/acme/live/example.com/fullchain.pem" "$source_backup/shared/acme/archive/example.com/fullchain1.pem"
printf 'target,path\n../../archive/example.com/fullchain1.pem,shared/acme/live/example.com/fullchain.pem\n' >"$source_backup/issuer_links.csv"
snapshot_source >"$TEST_WORK/before"
domain_config_restore_backup "$source_backup" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test 'True format-2 backup conversion failed'; }
snapshot_source >"$TEST_WORK/after"
cmp -s "$TEST_WORK/before" "$TEST_WORK/after" || fail_test 'Restore conversion changed original backup bytes'
[ "$(readlink "$result/shared/acme/live/example.com/fullchain.pem")" = ../../archive/example.com/fullchain1.pem ] || fail_test 'Reordered issuer-link table did not reconstruct the exact contained link'
for invalid in duplicate wrong-lineage mismatched-material; do
  issuer_test="$TEST_WORK/issuer-$invalid"
  mkdir -p "$issuer_test"
  cp -R "$source_backup/shared" "$issuer_test/"
  cp "$source_backup/issuer_links.csv" "$issuer_test/issuer_links.csv"
  case "$invalid" in
  duplicate) printf '../../archive/example.com/fullchain1.pem,shared/acme/live/example.com/fullchain.pem\n' >>"$issuer_test/issuer_links.csv" ;;
  wrong-lineage) printf 'target,path\n../../archive/other.example.com/fullchain1.pem,shared/acme/live/example.com/fullchain.pem\n' >"$issuer_test/issuer_links.csv" ;;
  mismatched-material) printf 'different issuer material\n' >"$issuer_test/shared/acme/live/example.com/fullchain.pem" ;;
  esac
  if _domain_backup_restore_issuer_links "$issuer_test" >"$TEST_WORK/rejected" 2>&1; then fail_test "Reordered issuer-link table accepted $invalid"; fi
done
mkdir -p "$TEST_WORK/issuer-empty"
printf 'target,path\n' >"$TEST_WORK/issuer-empty/issuer_links.csv"
_domain_backup_restore_issuer_links "$TEST_WORK/issuer-empty" || fail_test 'Empty reordered issuer-link table was rejected'
[ "$(domain_config_get "$result/domains/example.com/config" settings.csv http_version)" = http1.0 ] || fail_test 'Conversion applied or lost the pending draft'
[ "$(domain_config_get "$result/candidate/example.com/config" settings.csv http_version)" = http1.1 ] || fail_test 'Conversion lost the accepted snapshot'
[ "$(_domain_runtime_get "$result/domains/example.com/runtime/backend.csv" state)" = stopped ] || fail_test 'Conversion lost runtime metadata'
[ "$(_domain_runtime_get "$result/domains/example.com/runtime/observed.csv" address)" = 172.20.0.3 ] || fail_test 'Conversion lost observed metadata'
[ "$(_domain_runtime_get "$result/domains/example.com/certs/upload/certificate.csv" specification)" = "$specification" ] || fail_test 'Conversion changed the certificate receipt fingerprint'
[ "$(_domain_runtime_get "$result/domains/example.com/certs/upload/certificate.csv" source_fullchain)" = /missing/import/fullchain.pem ] || fail_test 'Conversion lost implicit accepted custom import metadata'
cmp -s "$material/privkey.pem" "$result/domains/example.com/certs/upload/privkey.pem" || fail_test 'Conversion changed private material'
grep -q EXAMPLE_EXTENSION "$result/input/config/global_settings.csv" || fail_test 'Conversion lost an inert shared setting'

# A genuine schema-3 archive keeps its split tables, including a pending draft.
# Public restore must select the older codec before strict schema-5 validation.
source3="$TEST_WORK/format3"
cp -R "$source_backup" "$source3"
for part in config runtime/applied; do
  (
    DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3
    _domain_csv_convert_v2_directory "$source3/domains/example.com/$part" "$TEST_WORK/schema3-converted"
  )
  rm -rf "$source3/domains/example.com/$part"
  mv "$TEST_WORK/schema3-converted" "$source3/domains/example.com/$part"
done
_domain_config_convert_shared_config "$source3/config" "$TEST_WORK/shared3"
rm -rf "$source3/config"
mv "$TEST_WORK/shared3" "$source3/config"
(
  DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3 DOMAIN_CONFIG_LEGACY_RECOVERY=true
  _domain_config_convert_runtime_metadata "$source3/domains/example.com" "$TEST_WORK/metadata3" "$source3/domains/example.com/runtime/applied"
)
cp "$TEST_WORK/metadata3/runtime/"*.csv "$source3/domains/example.com/runtime/"
cp "$TEST_WORK/metadata3/certs/upload/certificate.csv" "$source3/domains/example.com/certs/upload/certificate.csv"
printf 'format_version,state_schema_version\n3,3\n' >"$source3/backup_manifest.csv"
printf '3\n' >"$source3/config/state_schema_version"
result="$TEST_WORK/converted3"
domain_config_restore_backup "$source3" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test 'True format-3 backup conversion failed'; }
[ "$(domain_config_get "$result/domains/example.com/config" settings.csv http_version)" = http1.0 ] || fail_test 'Format-3 restore lost the pending draft'
[ "$(domain_config_get "$result/candidate/example.com/config" settings.csv http_version)" = http1.1 ] || fail_test 'Format-3 restore activated a draft'
[ ! -e "$result/candidate/example.com/config/certificate_options.csv" ] || fail_test 'Format-3 restore retained split declarations'
[ "$(domain_config_certificate_option "$result/candidate/example.com/config" upload source_fullchain)" = /missing/import/fullchain.pem ] || fail_test 'Format-3 restore lost its import reference'
cmp -s "$material/privkey.pem" "$result/domains/example.com/certs/upload/privkey.pem" || fail_test 'Format-3 restore changed private material'

# Both consumers must accept reordered certificate declarations. Provisioning
# must reuse the managed pair after its original import paths have disappeared.
printf 'provider,port_suffix,certificate_id,source_privkey,source_fullchain\ncustom,443,upload,/missing/import/privkey.pem,/missing/import/fullchain.pem\n' >"$result/candidate/example.com/config/certificates.csv"
_domain_restore_prepare_certificates "$result"
(
  DOMAIN_CONFIG_ACTIVE=true
  DOMAINS_DIR="$result/domains"
  domain_config_provision_certificates "$result/candidate"
)
[ "$(_domain_runtime_get "$result/domains/example.com/certs/upload/certificate.csv" declared)" = yes ] || fail_test 'Reordered declarations failed to retain active material'
printf 'provider,port_suffix,certificate_id,source_privkey,source_fullchain\n' >"$result/candidate/example.com/config/certificates.csv"
(
  DOMAIN_CONFIG_ACTIVE=true
  DOMAINS_DIR="$result/domains"
  domain_config_provision_certificates "$result/candidate"
)
[ "$(_domain_runtime_get "$result/domains/example.com/certs/upload/certificate.csv" declared)" = no ] || fail_test 'Empty reordered declaration table did not retain omitted material'
printf '[PASS] format-2 backup conversion preserves drafts, custom material and original bytes\n'
