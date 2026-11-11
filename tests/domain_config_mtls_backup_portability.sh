#!/usr/bin/env bash
# Fixture settings are consumed by sourced production modules.
# shellcheck disable=SC2034,SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-mtls-backup-portability.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
TEST_COMPLETE=false
test_status=0
trap 'test_status=$?; rm -rf "$TEST_WORK"; if [ "$TEST_COMPLETE" != true ] && [ "$test_status" -eq 0 ]; then test_status=1; fi; exit "$test_status"' EXIT
export SKIP_DOCKER_CHECKS=true CERT_AUTOCONFIG_DISABLED=1
SOURCE="$TEST_WORK/source"
DESTINATION="$TEST_WORK/destination"
OWNER=portable.example.com
DOMAIN="$DESTINATION/state/domains/$OWNER"
BIN=""

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function prepare_installation() {
  local installation="$1"
  mkdir -p "$installation"
  cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$installation/"
  (
    source "$installation/lib/config.sh"
    source "$installation/lib/utils.sh"
    mkdir -p "$CONFIG_DIR"
    state_csv_ensure_all_state_files
    ENABLE_AUTO_BACKUPS=false ENABLE_BACKUP_COMPRESSION=false
    _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
    printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
  )
}
function assert_owned_mapping() {
  local directory=""
  [ "$(test_csv_field "$DOMAIN/runtime/applied/mtls.csv" enabled)" = yes ] || fail_test 'Restore disabled applied mTLS'
  directory="$(test_csv_field "$DOMAIN/runtime/applied/mtls.csv" directory)"
  case "$directory" in '' | "$DOMAIN/mtls") ;; *) fail_test 'Restore published a foreign applied mTLS path' ;; esac
  printf 'domain,mtls_directory\n%s,%s\n' "$OWNER" "$DOMAIN/mtls" >"$TEST_WORK/expected-mapping"
  cmp -s "$TEST_WORK/expected-mapping" "$DESTINATION/state/config/backend_mtls.csv" || fail_test 'Restore did not publish the exact destination-owned aggregate mTLS path'
  grep -Fq "ssl_client_certificate /etc/letsencrypt/$OWNER/mtls/ca.crt;" "$DOMAIN/generated/nginx/http.conf" || fail_test 'Restored configuration does not use the owned client CA'
  grep -Fq 'ssl_verify_client on;' "$DOMAIN/generated/nginx/http.conf" || fail_test 'Restored configuration does not require client certificates'
  grep -Fq "ssl_crl /etc/letsencrypt/$OWNER/mtls/ca.crl;" "$DOMAIN/generated/nginx/http.conf" || fail_test 'Restored configuration does not use the owned CRL'
}
function assert_material() {
  local archive="$1" file="" mode=""
  for file in ca.crt ca.key ca.crl archived-client.crt archived-client.key; do
    cmp -s "$archive/domains/$OWNER/mtls/$file" "$DOMAIN/mtls/$file" || fail_test "Restore changed archived mTLS material: $file"
  done
  mode="$(stat -c '%a' "$DOMAIN/mtls/ca.key" 2>/dev/null || stat -f '%Lp' "$DOMAIN/mtls/ca.key")"
  [ "$mode" = 600 ] || fail_test 'Restore widened the mTLS authority key permissions'
  openssl verify -CAfile "$DOMAIN/mtls/ca.crt" "$DOMAIN/mtls/archived-client.crt" >/dev/null 2>&1 || fail_test 'Restored client no longer verifies against the archived CA'
}
function snapshot_runtime() {
  rm -rf "$TEST_WORK/before"
  mkdir -p "$TEST_WORK/before"
  cp -R "$DOMAIN/runtime/applied" "$DOMAIN/generated" "$DOMAIN/mtls" "$TEST_WORK/before/"
  cp -R "$DOMAIN/config" "$TEST_WORK/before/draft"
  cp "$DESTINATION/state/config/backend_mtls.csv" "$TEST_WORK/before/backend_mtls.csv"
  cp "$DOMAIN/config/headers.csv" "$TEST_WORK/before/draft-headers.csv"
}
function assert_runtime_unchanged() {
  diff -r "$TEST_WORK/before/applied" "$DOMAIN/runtime/applied" >/dev/null || fail_test 'Rejected restore changed applied domain configuration'
  diff -r "$TEST_WORK/before/generated" "$DOMAIN/generated" >/dev/null || fail_test 'Rejected restore changed generated domain configuration'
  diff -r "$TEST_WORK/before/mtls" "$DOMAIN/mtls" >/dev/null || fail_test 'Rejected restore changed mTLS material'
  cmp -s "$TEST_WORK/before/backend_mtls.csv" "$DESTINATION/state/config/backend_mtls.csv" || fail_test 'Rejected restore changed aggregate mTLS state'
}

# Use real CLI dispatch, backup intake, CA/client generation and restore
# transactions. A stopped backend keeps this regression independent of Docker.
prepare_installation "$SOURCE"
prepare_installation "$DESTINATION"
BIN="$SOURCE/dockistrate.sh"
run_cli init-domain-config "$OWNER"
source_domain="$SOURCE/state/domains/$OWNER"
test_domain_csv_set "$source_domain/config/backend.csv" image nginx:alpine
test_domain_csv_set "$source_domain/config/backend.csv" container_port 8443
test_domain_csv_set "$source_domain/config/backend.csv" state stopped
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n38443,8443,https,%s,selfsigned-38443,no,off,,off,auto\n' "$OWNER" >"$source_domain/config/ports.csv"
printf 'certificate_id,provider,port_suffix,source_fullchain,source_privkey\nselfsigned-38443,selfsigned,38443,,\n' >"$source_domain/config/certificates.csv"
run_cli apply-domain-config "$OWNER"
run_cli enable-backend-mtls "$OWNER" archived-client
for part in config runtime/applied; do
  [ "$(test_csv_field "$source_domain/$part/mtls.csv" enabled)" = yes ] || fail_test 'Enabling mTLS did not publish its enabled setting'
  [ "$(test_csv_field "$source_domain/$part/mtls.csv" directory)" = '' ] || fail_test 'New mTLS exports retain the source checkout path'
done
run_cli create-backup portable-mtls
backup="$(cat "$SOURCE/state/backups/last_full_backup.txt")"
[ -d "$backup" ] || fail_test 'Fixture expected the public uncompressed backup format'
archive="$TEST_WORK/archive-current"
historical="$TEST_WORK/archive-absolute"
cp -R "$backup" "$archive"
cp -R "$archive" "$historical"
# Previously written archives contain an absolute path in accepted state.
# Reconstruct it explicitly even after new exports use the implicit owned path.
test_domain_csv_set "$historical/domains/$OWNER/runtime/applied/mtls.csv" directory "$source_domain/mtls"
test_domain_csv_set "$historical/domains/$OWNER/config/mtls.csv" directory "$source_domain/mtls"
test_domain_csv_set "$historical/domains/$OWNER/config/mtls.csv" enabled no
printf 'header_type,header_name,header_value\nresponse,X-Draft,pending\n' >"$historical/domains/$OWNER/config/headers.csv"
cp -R "$archive" "$TEST_WORK/archive-current-before"
cp -R "$historical" "$TEST_WORK/archive-absolute-before"
mv "$SOURCE" "$TEST_WORK/source-unavailable"
[ ! -e "$SOURCE" ] || fail_test 'Source installation remains available to restore'

BIN="$DESTINATION/dockistrate.sh"
printf '[tests] Restoring enabled mTLS into a distinct installation with the source unavailable\n'
run_cli restore-backup "$archive"
assert_owned_mapping
assert_material "$archive"
run_cli validate-domain-config "$OWNER"
cmp -s "$DOMAIN/config/mtls.csv" "$DOMAIN/runtime/applied/mtls.csv" || fail_test 'Relocation introduced an accidental mTLS draft difference'
diff -r "$TEST_WORK/archive-current-before" "$archive" >/dev/null || fail_test 'Restore changed current archive bytes'

run_cli restore-backup "$historical"
assert_owned_mapping
assert_material "$historical"
[ "$(test_csv_field "$DOMAIN/config/mtls.csv" enabled)" = no ] || fail_test 'Restore lost the pending mTLS disable setting'
directory="$(test_csv_field "$DOMAIN/config/mtls.csv" directory)"
case "$directory" in '' | "$DOMAIN/mtls") ;; *) fail_test 'Restore left a well-formed editable mTLS path tied to the source' ;; esac
cmp -s "$historical/domains/$OWNER/config/headers.csv" "$DOMAIN/config/headers.csv" || fail_test 'Restore changed the pending header draft'
cmp -s "$historical/domains/$OWNER/runtime/applied/headers.csv" "$DOMAIN/runtime/applied/headers.csv" || fail_test 'Restore activated the pending header draft'
diff -r "$TEST_WORK/archive-absolute-before" "$historical" >/dev/null || fail_test 'Restore changed historical archive bytes'
printf '[tests] Current and historical absolute-path mTLS archives restored successfully\n'

# Only an owned historical path may relocate. Invalid accepted paths must fail
# before publication even though the archive contains a valid CA/key pair.
snapshot_runtime
for invalid in "$TEST_WORK/external-mtls" "$SOURCE/state/domains/other.example.com/mtls" "$source_domain/../other.example.com/mtls" '../../mtls'; do
  rejected="$TEST_WORK/archive-rejected"
  rm -rf "$rejected"
  cp -R "$historical" "$rejected"
  test_domain_csv_set "$rejected/domains/$OWNER/runtime/applied/mtls.csv" directory "$invalid"
  if "$BASH" "$BIN" restore-backup "$rejected" >"$TEST_WORK/output" 2>&1; then fail_test "Restore silently relocated invalid mTLS path: $invalid"; fi
  assert_runtime_unchanged
  diff -r "$TEST_WORK/before/draft" "$DOMAIN/config" >/dev/null || fail_test 'Rejected path changed the pending draft'
done

# Unfinished current-format drafts are operator bytes. They remain restorable
# and pending even when their mTLS record cannot be parsed for relocation.
opaque="$TEST_WORK/archive-opaque"
cp -R "$historical" "$opaque"
printf '%s\n' 'enabled,directory' 'no,"unfinished' >"$opaque/domains/$OWNER/config/mtls.csv"
printf '%s\n' 'unfinished,"draft' >"$opaque/domains/$OWNER/config/headers.csv"
run_cli restore-backup "$opaque"
assert_owned_mapping
cmp -s "$opaque/domains/$OWNER/config/mtls.csv" "$DOMAIN/config/mtls.csv" || fail_test 'Restore rewrote malformed draft mTLS bytes'
cmp -s "$opaque/domains/$OWNER/config/headers.csv" "$DOMAIN/config/headers.csv" || fail_test 'Restore rewrote unrelated malformed draft bytes'

# Publication must roll back material and paths after a real render succeeds,
# while preserving a draft edit made concurrently with the failed restore.
printf '\n' >>"$DOMAIN/mtls/ca.key"
printf 'current-only material\n' >"$DOMAIN/mtls/current-only"
snapshot_runtime
cat >"$DESTINATION/lib/nginx/zz_mtls_restore_failure.sh" <<'HOOK'
# shellcheck shell=bash
eval "$(declare -f _update_nginx_config_from_validated_settings | sed '1s/_update_nginx_config_from_validated_settings/_test_mtls_restore_render/')"
function _update_nginx_config_from_validated_settings() {
  _test_mtls_restore_render || return 1
  if [ "${FAIL_MTLS_RESTORE_AFTER_RENDER:-false}" = true ]; then
    cp "$STATE_DIR/domains/portable.example.com/mtls/ca.key" "$BASE_DIR/published-ca.key" || return 1
    cp "$BACKEND_MTLS_FILE" "$BASE_DIR/published-mtls.csv" || return 1
    printf 'header_type,header_name,header_value\nresponse,X-Concurrent,keep\n' >"$STATE_DIR/domains/portable.example.com/config/headers.csv"
    printf '[Error] Injected failure after restored mTLS rendering.\n' >&2
    return 1
  fi
}
HOOK
if FAIL_MTLS_RESTORE_AFTER_RENDER=true "$BASH" "$BIN" restore-backup "$historical" >"$TEST_WORK/output" 2>&1; then fail_test 'Restore ignored a late activation failure'; fi
grep -Fq 'Injected failure after restored mTLS rendering.' "$TEST_WORK/output" || fail_test 'Restore did not reach the intended failure point'
cmp -s "$historical/domains/$OWNER/mtls/ca.key" "$DESTINATION/published-ca.key" || fail_test 'Failure injection did not observe archived mTLS material publication'
cmp -s "$TEST_WORK/expected-mapping" "$DESTINATION/published-mtls.csv" || fail_test 'Failure injection did not observe the destination-owned mTLS mapping'
assert_runtime_unchanged
printf 'header_type,header_name,header_value\nresponse,X-Concurrent,keep\n' >"$TEST_WORK/expected-draft"
cmp -s "$TEST_WORK/expected-draft" "$DOMAIN/config/headers.csv" || fail_test 'Restore rollback overwrote the concurrent draft edit'
diff -r "$TEST_WORK/archive-absolute-before" "$historical" >/dev/null || fail_test 'Failed restore changed historical archive bytes'
TEST_COMPLETE=true
printf '[PASS] mTLS backups relocate owned paths, preserve material/drafts, reject unsafe paths and roll back failures\n'
