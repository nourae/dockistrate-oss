#!/usr/bin/env bash
# Fixture globals are consumed by sourced production configuration helpers.
# shellcheck disable=SC2034,SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-mtls-integrity.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
TEST_COMPLETE=false
test_status=0
trap 'test_status=$?; rm -rf "$TEST_WORK"; if [ "$TEST_COMPLETE" != true ] && [ "$test_status" -eq 0 ]; then test_status=1; fi; exit "$test_status"' EXIT
TEST_CASE="${1:-all}"
case "$TEST_CASE" in all | reuse | missing-ca.crt | missing-ca.key | missing-index.txt) ;; *) exit 2 ;; esac
# Keep general restore staging physical; the hook below introduces an owned
# workspace alias only at the mTLS material-preparation boundary.
mkdir "$TEST_WORK/temporary"
export TMPDIR="$TEST_WORK/temporary"
INSTALL="$TEST_WORK/install"
mkdir -p "$INSTALL"
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$INSTALL/"
export SKIP_DOCKER_CHECKS=true CERT_AUTOCONFIG_DISABLED=1 LC_ALL=C
BIN="$INSTALL/dockistrate.sh"
OWNER=integrity.example.com
DOMAIN="$INSTALL/state/domains/$OWNER"
MTLS_DIR="$DOMAIN/mtls"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function snapshot_runtime() {
  python3 - "$INSTALL/state" "$1" "${2:-include-drafts}" <<'PY'
import hashlib, json, pathlib, stat, sys
root, output, drafts = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
files = list((root / 'config').rglob('*')) + list((root / 'shared').rglob('*'))
for domain in (root / 'domains').iterdir():
    for part in ['runtime/applied', 'generated', 'mtls', 'certs'] + (['config'] if drafts == 'include-drafts' else []):
        files += list((domain / part).rglob('*'))
result = {}
for path in files:
    if path.is_file():
        result[str(path.relative_to(root))] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                              'mode': stat.S_IMODE(path.stat().st_mode)}
output.write_text(json.dumps(result, sort_keys=True))
PY
}
function assert_unchanged() {
  snapshot_runtime "$TEST_WORK/after.json" "${1:-include-drafts}"
  if ! cmp -s "$TEST_WORK/before.json" "$TEST_WORK/after.json"; then
    python3 - "$TEST_WORK/before.json" "$TEST_WORK/after.json" <<'PY_DIFF'
import json, sys
before, after = [json.load(open(path)) for path in sys.argv[1:]]
for path in sorted(set(before) | set(after)):
    if before.get(path) != after.get(path):
        print(json.dumps({'path': path, 'before': before.get(path), 'after': after.get(path)}, sort_keys=True))
PY_DIFF
    fail_test "${2:-Rejected operation} changed source, applied, aggregate, generated or certificate state"
  fi
}
function assert_core_material() {
  local file="" reference="$1"
  for file in ca.crt ca.key index.txt serial valid-client.crt valid-client.key revoked-client.crt revoked-client.key; do
    cmp -s "$reference/domains/$OWNER/mtls/$file" "$MTLS_DIR/$file" || fail_test "Restore changed original mTLS material: $file"
  done
  openssl verify -CAfile "$MTLS_DIR/ca.crt" -CRLfile "$MTLS_DIR/ca.crl" -crl_check "$MTLS_DIR/valid-client.crt" >"$TEST_WORK/output" 2>&1 || fail_test 'Restored valid client failed verification'
  if openssl verify -CAfile "$MTLS_DIR/ca.crt" -CRLfile "$MTLS_DIR/ca.crl" -crl_check "$MTLS_DIR/revoked-client.crt" >"$TEST_WORK/output" 2>&1; then fail_test 'Restore reinstated revoked client'; fi
}
function reject_restore() {
  local archive="$1"
  snapshot_runtime "$TEST_WORK/before.json"
  rm -f "$INSTALL/restore-activation-reached"
  if "$BASH" "$BIN" restore-backup "$archive" >"$TEST_WORK/output" 2>&1; then fail_test "Incomplete authority restored successfully: ${archive##*/}"; fi
  [ ! -e "$INSTALL/restore-activation-reached" ] || fail_test 'Incomplete authority reached runtime activation before rejection'
  grep -Fq '[Error] Invalid mTLS authority state:' "$TEST_WORK/output" || fail_test 'Restore did not explain the damaged mTLS material'
  assert_unchanged
}

# Stopped backends retain real CLI dispatch, transactions, certificate creation,
# applied/source publication and rendering while avoiding Docker dependencies.
(
  source "$INSTALL/lib/config.sh"
  source "$INSTALL/lib/utils.sh"
  source "$INSTALL/lib/domain_config.sh"
  mkdir -p "$CONFIG_DIR"
  state_csv_ensure_all_state_files
  ENABLE_AUTO_BACKUPS=false ENABLE_BACKUP_COMPRESSION=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
  for name in "$OWNER" disabled.example.com; do
    config="$INSTALL/state/domains/$name/config"
    domain_config_write_template "$name" backend "$config"
    _domain_csv_set "$config/backend.csv" image nginx:alpine
    _domain_csv_set "$config/backend.csv" container_port 8443
    _domain_csv_set "$config/backend.csv" state stopped
  done
  config="$INSTALL/state/domains/admin.integrity.example.com/config"
  domain_config_write_template admin.integrity.example.com dedicated "$config"
  _domain_csv_set "$config/domain.csv" target "$OWNER"
  config="$DOMAIN/config"
  csv_join_row 38443 8443 https "$OWNER" selfsigned-38443 no off '' off auto >>"$config/ports.csv"
  csv_join_row selfsigned-38443 selfsigned 38443 '' '' >>"$config/certificates.csv"
)
run_cli apply-domain-config --all
run_cli enable-backend-mtls "$OWNER" valid-client
cp "$MTLS_DIR/ca.crl" "$TEST_WORK/prerevocation.crl"
run_cli add-backend-client-cert "$OWNER" revoked-client
run_cli revoke-backend-client-cert "$OWNER" revoked-client
mkdir -p "$INSTALL/state/domains/disabled.example.com/mtls"
printf 'retained disabled material\n' >"$INSTALL/state/domains/disabled.example.com/mtls/retained.key"
# An unapplied enable draft must not cause restore to repair partial material.
printf 'enabled,directory\nyes,\n' >"$INSTALL/state/domains/disabled.example.com/config/mtls.csv"
printf 'header_type,header_name,header_value\nresponse,X-Archive-Draft,pending\n' >"$DOMAIN/config/headers.csv"
run_cli create-backup integrity-fixture
backup="$(cat "$INSTALL/state/backups/last_full_backup.txt")"
[ -d "$backup" ] || fail_test 'Fixture expected an uncompressed backup'
archive="$TEST_WORK/complete"
cp -pR "$backup" "$archive"
cp -pR "$archive" "$TEST_WORK/archive-before"
printf 'header_type,header_name,header_value\nresponse,X-Current-Draft,keep\n' >"$DOMAIN/config/headers.csv"

# This marker distinguishes staged rejection from later failure/rollback. The
# same hook supplies a late failure after genuine rendering for rollback tests.
cat >"$INSTALL/lib/nginx/zz_mtls_integrity_test.sh" <<'HOOK'
# shellcheck shell=bash
# macOS temporary paths commonly use /var -> /private/var. Exercise equivalent
# alias resolution at this boundary on every platform, without bypassing any
# earlier restore guards. Remove the owned alias before activation or cleanup.
eval "$(declare -f _domain_restore_prepare_mtls | sed '1s/_domain_restore_prepare_mtls/_test_integrity_prepare_mtls/')"
function _domain_restore_prepare_mtls() {
  local test_prepared_alias="$1/mtls-preparation-alias" test_prepare_status=0
  ln -s . "$test_prepared_alias" || return 1
  _test_integrity_prepare_mtls "$test_prepared_alias" || test_prepare_status=$?
  rm "$test_prepared_alias" || return 1
  return "$test_prepare_status"
}
eval "$(declare -f _domain_restore_activate | sed '1s/_domain_restore_activate/_test_integrity_activate/')"
function _domain_restore_activate() {
  : >"$BASE_DIR/restore-activation-reached"
  _test_integrity_activate "$@"
}
eval "$(declare -f _update_nginx_config_from_validated_settings | sed '1s/_update_nginx_config_from_validated_settings/_test_integrity_render/')"
function _update_nginx_config_from_validated_settings() {
  _test_integrity_render || return 1
  if [ "${FAIL_MTLS_INTEGRITY_AFTER_RENDER:-false}" = true ] && [ ! -e "$BASE_DIR/published-ca.key" ]; then
    cp "$STATE_DIR/domains/integrity.example.com/mtls/ca.key" "$BASE_DIR/published-ca.key" || return 1
    printf 'header_type,header_name,header_value\nresponse,X-Concurrent,keep\n' >"$STATE_DIR/domains/integrity.example.com/config/headers.csv"
    printf '[Error] Injected mTLS integrity restore failure after rendering.\n' >&2
    return 1
  fi
}
HOOK

function check_reuse_and_replacement() {
  # Existing enabled state with missing authority is corruption, while explicit
  # CA replacement remains an intentional recovery/reset command.
  cp "$DOMAIN/runtime/applied/headers.csv" "$DOMAIN/config/headers.csv"
  cp "$MTLS_DIR/valid-client.crt" "$TEST_WORK/old-client.crt"
  rm "$MTLS_DIR/ca.crt"
  snapshot_runtime "$TEST_WORK/before.json"
  if "$BASH" "$BIN" apply-domain-config "$OWNER" --dry-run >"$TEST_WORK/output" 2>&1; then fail_test 'Dry-run apply accepted missing authority material'; fi
  assert_unchanged include-drafts 'Dry-run apply with missing ca.crt'
  if "$BASH" "$BIN" apply-domain-config admin.integrity.example.com >"$TEST_WORK/output" 2>&1; then fail_test 'Dedicated-host apply ignored damaged inherited authority'; fi
  assert_unchanged include-drafts 'Dedicated-host apply with missing inherited ca.crt'
  if "$BASH" "$BIN" enable-backend-mtls "$OWNER" >"$TEST_WORK/output" 2>&1; then fail_test 'Re-enable silently replaced a damaged authority'; fi
  assert_unchanged include-drafts 'Re-enable with missing ca.crt'
  mv "$MTLS_DIR" "$TEST_WORK/missing-entire-authority"
  snapshot_runtime "$TEST_WORK/before.json"
  if "$BASH" "$BIN" enable-backend-mtls "$OWNER" >"$TEST_WORK/output" 2>&1; then fail_test 'Re-enable replaced an entirely missing enabled authority'; fi
  assert_unchanged include-drafts 'Re-enable with missing authority directory'
  if "$BASH" "$BIN" apply-domain-config "$OWNER" >"$TEST_WORK/output" 2>&1; then fail_test 'Apply replaced an entirely missing enabled authority'; fi
  assert_unchanged include-drafts 'Apply with missing authority directory'
  run_cli create-backup damaged-recovery
  recovery_backup="$(cat "$INSTALL/state/backups/last_full_backup.txt")"
  [ -d "$recovery_backup" ] || fail_test 'Damaged authority prevented a recovery snapshot'
  run_cli replace-backend-ca "$OWNER"
  [ -f "$MTLS_DIR/ca.crt" ] && [ -f "$MTLS_DIR/ca.key" ] && [ -f "$MTLS_DIR/ca.crl" ] || fail_test 'Explicit CA replacement did not recreate complete authority'
  [ ! -s "$MTLS_DIR/index.txt" ] || fail_test 'Explicit CA replacement did not reset history'
  if openssl verify -CAfile "$MTLS_DIR/ca.crt" "$TEST_WORK/old-client.crt" >"$TEST_WORK/output" 2>&1; then fail_test 'Explicit CA replacement kept the old authority'; fi
}

if [ "$TEST_CASE" = reuse ]; then
  printf '\n' >>"$MTLS_DIR/ca.key"
  (umask 027; printf 'current-only\n' >"$MTLS_DIR/current-only")
  check_reuse_and_replacement
  TEST_COMPLETE=true
  printf '[PASS] Missing enabled authority is rejected unchanged; explicit replacement and recovery snapshots work\n'
  exit 0
fi

for file in ca.crt ca.key index.txt serial crlnumber; do
  case "$TEST_CASE" in all | "missing-$file") ;; *) continue ;; esac
  damaged="$TEST_WORK/missing-$file"
  cp -pR "$archive" "$damaged"
  rm "$damaged/domains/$OWNER/mtls/$file"
  reject_restore "$damaged"
  printf '[PASS] Public restore rejects missing %s before activation\n' "$file"
done
if [ "$TEST_CASE" != all ]; then TEST_COMPLETE=true; exit 0; fi

damaged="$TEST_WORK/empty-history"
cp -pR "$archive" "$damaged"
: >"$damaged/domains/$OWNER/mtls/index.txt"
reject_restore "$damaged"

damaged="$TEST_WORK/stale-signed-crl"
cp -pR "$archive" "$damaged"
cp "$TEST_WORK/prerevocation.crl" "$damaged/domains/$OWNER/mtls/ca.crl"
reject_restore "$damaged"

# Use the real no-command picker and its manual-path restore flow. Dynamic menu
# positions keep the test coupled to discoverability rather than hardcoded UI.
rm -rf "$INSTALL/state/backups"
mkdir -p "$INSTALL/state/backups"
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
advanced_choice='' category_choice='' restore_choice=''
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_HOME_OPTIONS[@]}; idx++)); do
  [ "${INTERACTIVE_PICKER_HOME_OPTIONS[$idx]}" != "$INTERACTIVE_PICKER_HOME_ADVANCED_LABEL" ] || advanced_choice=$((idx + 1))
done
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_CATEGORIES[@]}; idx++)); do
  [ "${INTERACTIVE_PICKER_CATEGORIES[$idx]}" != 'Backups & Restore' ] || category_choice=$((idx + 2))
done
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_COMMANDS_BACKUPS_RESTORE[@]}; idx++)); do
  [ "${INTERACTIVE_PICKER_COMMANDS_BACKUPS_RESTORE[$idx]}" != restore-backup ] || restore_choice=$((idx + 1))
done
for choice in "$advanced_choice" "$category_choice" "$restore_choice"; do [ -n "$choice" ] || fail_test 'Restore picker entry is missing'; done
snapshot_runtime "$TEST_WORK/before.json"
rm -f "$INSTALL/restore-activation-reached"
printf '%s\n%s\n%s\n2\n%s\n\n1\ny\n\nq\n' "$advanced_choice" "$category_choice" "$restore_choice" "$TEST_WORK/missing-index.txt" |
  "$BASH" "$BIN" -i >"$TEST_WORK/output" 2>&1 || true
grep -Fq 'index.txt' "$TEST_WORK/output" || fail_test 'Interactive restore did not report the missing history file'
[ ! -e "$INSTALL/restore-activation-reached" ] || fail_test 'Interactive restore activated an incomplete authority'
assert_unchanged

run_cli restore-backup "$archive"
assert_core_material "$archive"
for file in ca.crl crlnumber; do cmp -s "$archive/domains/$OWNER/mtls/$file" "$MTLS_DIR/$file" || fail_test "Complete restore rewrote $file"; done
cmp -s "$archive/domains/$OWNER/config/headers.csv" "$DOMAIN/config/headers.csv" || fail_test 'Restore lost archived pending draft'
cmp -s "$archive/domains/$OWNER/runtime/applied/headers.csv" "$DOMAIN/runtime/applied/headers.csv" || fail_test 'Restore activated archived pending draft'
cmp -s "$archive/domains/disabled.example.com/mtls/retained.key" "$INSTALL/state/domains/disabled.example.com/mtls/retained.key" || fail_test 'Restore changed disabled retained material'
for part in config runtime/applied; do
  cmp -s "$archive/domains/disabled.example.com/$part/mtls.csv" "$INSTALL/state/domains/disabled.example.com/$part/mtls.csv" || fail_test 'Restore changed pending disabled-domain mTLS draft or applied state'
done
printf '[PASS] Complete restore preserves authority/history, disabled material and pending drafts\n'

derived="$TEST_WORK/missing-derived"
cp -pR "$archive" "$derived"
rm "$derived/domains/$OWNER/mtls/ca.crl" "$derived/domains/$OWNER/mtls/openssl.cnf"
rm -rf "$derived/domains/$OWNER/mtls/newcerts"
cp -pR "$derived" "$TEST_WORK/derived-before"
run_cli restore-backup "$derived"
assert_core_material "$archive"
[ -f "$MTLS_DIR/openssl.cnf" ] && [ -d "$MTLS_DIR/newcerts" ] || fail_test 'Restore did not recreate derived configuration/output directory'
diff -r "$TEST_WORK/derived-before" "$derived" >/dev/null || fail_test 'Derived recovery changed archive bytes'
printf '[PASS] Missing-derived restore preserves identity and revocations without changing archive bytes\n'

# A real activation failure must restore all previous runtime/material while
# preserving an editable draft changed concurrently with the failed restore.
printf '\n' >>"$MTLS_DIR/ca.key"
(umask 027; printf 'current-only\n' >"$MTLS_DIR/current-only")
snapshot_runtime "$TEST_WORK/before.json" exclude-drafts
if FAIL_MTLS_INTEGRITY_AFTER_RENDER=true "$BASH" "$BIN" restore-backup "$archive" >"$TEST_WORK/output" 2>&1; then fail_test 'Restore ignored injected activation failure'; fi
grep -Fq 'Injected mTLS integrity restore failure after rendering.' "$TEST_WORK/output" || fail_test 'Restore did not reach late failure injection'
cmp -s "$archive/domains/$OWNER/mtls/ca.key" "$INSTALL/published-ca.key" || fail_test 'Failure hook did not observe restored material publication'
assert_unchanged exclude-drafts
printf 'header_type,header_name,header_value\nresponse,X-Concurrent,keep\n' >"$TEST_WORK/expected-draft"
cmp -s "$TEST_WORK/expected-draft" "$DOMAIN/config/headers.csv" || fail_test 'Rollback discarded concurrent draft'
printf '[PASS] Late restore rollback preserves runtime/material and concurrent draft\n'

check_reuse_and_replacement
diff -r "$TEST_WORK/archive-before" "$archive" >/dev/null || fail_test 'Restore changed original complete backup'
TEST_COMPLETE=true
printf '[PASS] CLI/picker reject incomplete mTLS before activation; valid/derived restore, revocations, disabled state, drafts and rollback remain intact\n'
