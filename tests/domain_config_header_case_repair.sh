#!/usr/bin/env bash
# Fixture globals are consumed by sourced production functions.
# shellcheck disable=SC1091,SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_header_case_repair.XXXXXXXX")"
trap 'exec 3>&-; rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
export SKIP_DOCKER_CHECKS=true
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"
OTHER="$TEST_WORK/state/domains/other.example.com"
CONFIG="$TEST_WORK/state/config"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "command failed: $*"; }; }
function reject_cli() {
  if "$BIN" "$@" >"$TEST_WORK/output" 2>&1; then fail_test "command unexpectedly succeeded: $*"; fi
}
function assert_same() { cmp -s "$1" "$2" || fail_test "$3"; }
function count_identity() {
  awk -F, -v type="$2" -v name="$3" 'NR > 1 && $1 == type && tolower($2) == tolower(name) { count++ } END { print count+0 }' "$1"
}
function seed_conflict() {
  printf 'header_type,header_name,header_value\nresponse,X-Repair,old\nresponse,x-repair,conflict\nrequest,X-Repair,request-value\n' >"$DOMAIN/config/headers.csv"
  cp "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv"
}
function snapshot_runtime() {
  rm -rf "$TEST_WORK/before-config" "$TEST_WORK/before-applied" "$TEST_WORK/before-generated"
  cp -R "$CONFIG" "$TEST_WORK/before-config"
  cp -R "$DOMAIN/runtime/applied" "$TEST_WORK/before-applied"
  cp -R "$DOMAIN/generated" "$TEST_WORK/before-generated"
}
function assert_runtime_unchanged() {
  diff -r "$TEST_WORK/before-config" "$CONFIG" >"$TEST_WORK/difference" || { cat "$TEST_WORK/difference" >&2; fail_test "$1 changed runtime configuration"; }
  diff -r "$TEST_WORK/before-applied" "$DOMAIN/runtime/applied" >"$TEST_WORK/difference" || fail_test "$1 changed applied files"
  diff -r "$TEST_WORK/before-generated" "$DOMAIN/generated" >"$TEST_WORK/difference" || fail_test "$1 changed domain-generated files"
}

function shared_header_editor_race() {
  local scenario="$1" race_status=0
  local -a command=(update-header response X-Shared command-value)
  printf '[TEST] Shared header editor race: %s\n' "$scenario"
  printf '%s\n' "$scenario" >"$TEST_WORK/shared-editor-scenario"
  cp "$CONFIG/custom_headers.csv" "$TEST_WORK/shared-original.csv"
  printf 'header_type,header_name,header_value\nresponse,X-Shared,original-value\n' >"$CONFIG/custom_headers.csv"
  cp "$CONFIG/custom_headers.csv" "$TEST_WORK/shared-editor-intended.csv"
  printf 'response,X-Editor,concurrent-value\n' >>"$TEST_WORK/shared-editor-intended.csv"
  case "$scenario" in
  global_before_publish)
    cat >"$TEST_WORK/lib/domain_config/zz_shared_header_editor.sh" <<'HOOK'
# shellcheck shell=bash
function _domain_config_publish_cache() {
  source "$BASE_DIR/lib/domain_config/common.sh"
  _domain_config_publish_cache "$@" || return 1
  cat "$BASE_DIR/shared-editor-intended.csv" >"$CUSTOM_HEADERS_FILE"
  printf 'injected\n' >"$BASE_DIR/shared-editor-injected"
}
HOOK
    ;;
  global_reload | backend_reload | global_deleted)
    if [ "$scenario" = backend_reload ]; then command=(update-backend-header example.com response X-Trace command-value); fi
    cat >"$TEST_WORK/lib/nginx/zz_shared_header_editor.sh" <<'HOOK'
# shellcheck shell=bash
function update_nginx_config() {
  source "$BASE_DIR/lib/nginx/update_nginx_config.sh"
  update_nginx_config "$@" || return 1
  if [ "$(cat "$BASE_DIR/shared-editor-scenario")" = global_deleted ]; then
    rm "$CUSTOM_HEADERS_FILE" || return 1
  else
    cat "$BASE_DIR/shared-editor-intended.csv" >"$CUSTOM_HEADERS_FILE"
  fi
  printf 'injected\n' >"$BASE_DIR/shared-editor-injected"
  return 1
}
HOOK
    ;;
  global_held_inode)
    exec 3>>"$CONFIG/custom_headers.csv"
    cat >"$TEST_WORK/lib/nginx/zz_shared_header_editor.sh" <<'HOOK'
# shellcheck shell=bash
function update_nginx_config() {
  source "$BASE_DIR/lib/nginx/update_nginx_config.sh"
  update_nginx_config "$@" || return 1
  printf 'response,X-Editor,concurrent-value\n' >&3
  printf 'injected\n' >"$BASE_DIR/shared-editor-injected"
}
HOOK
    ;;
  esac
  snapshot_runtime
  "$BIN" "${command[@]}" >"$TEST_WORK/output" 2>&1 || race_status=$?
  [ -f "$TEST_WORK/shared-editor-injected" ] || fail_test "$scenario hook did not execute"
  if [ "$scenario" = global_deleted ]; then
    [ ! -e "$CONFIG/custom_headers.csv" ] && [ ! -L "$CONFIG/custom_headers.csv" ] || fail_test 'global rollback resurrected the editor-deleted file'
  elif ! cmp -s "$TEST_WORK/shared-editor-intended.csv" "$CONFIG/custom_headers.csv"; then
    fail_test "$scenario discarded concurrent global header edits"
  fi
  [ "$race_status" -ne 0 ] || fail_test "$scenario accepted a revision changed by the editor"
  if [ "$scenario" = global_deleted ]; then
    rm "$TEST_WORK/before-config/custom_headers.csv"
  else
    cp "$TEST_WORK/shared-editor-intended.csv" "$TEST_WORK/before-config/custom_headers.csv"
  fi
  assert_runtime_unchanged "$scenario"
  assert_same "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv" "$scenario changed editable domain headers"
  if [ "$scenario" = global_held_inode ]; then
    printf 'response,X-Editor-After-Rollback,retained-inode\n' >&3
    grep -Fxq 'response,X-Editor-After-Rollback,retained-inode' "$CONFIG/custom_headers.csv" || fail_test 'global rollback replaced the held editor inode'
    exec 3>&-
  fi
  rm "$TEST_WORK/shared-editor-injected"
  for hook in "$TEST_WORK/lib/domain_config/zz_shared_header_editor.sh" "$TEST_WORK/lib/nginx/zz_shared_header_editor.sh"; do
    [ ! -f "$hook" ] || rm "$hook"
  done
  cp "$TEST_WORK/shared-original.csv" "$CONFIG/custom_headers.csv"
}

function missing_global_header_file() {
  local failure_status=0
  printf '[TEST] Backend mutation with a missing optional global header file\n'
  cp "$CONFIG/custom_headers.csv" "$TEST_WORK/missing-global-original.csv"
  rm "$CONFIG/custom_headers.csv"
  cat >"$TEST_WORK/lib/nginx/zz_shared_header_editor.sh" <<'HOOK'
# shellcheck shell=bash
function update_nginx_config() {
  source "$BASE_DIR/lib/nginx/update_nginx_config.sh"
  update_nginx_config "$@" || return 1
  printf 'rendered\n' >"$BASE_DIR/missing-global-rendered"
  return 1
}
HOOK
  snapshot_runtime
  "$BIN" update-backend-header example.com response X-Trace failed-value >"$TEST_WORK/output" 2>&1 || failure_status=$?
  [ -f "$TEST_WORK/missing-global-rendered" ] || fail_test 'missing-global backend mutation did not reach activation'
  [ "$failure_status" -ne 0 ] || fail_test 'missing-global backend mutation ignored activation failure'
  [ ! -e "$CONFIG/custom_headers.csv" ] && [ ! -L "$CONFIG/custom_headers.csv" ] || fail_test 'failed backend mutation did not restore missing global file'
  assert_runtime_unchanged 'missing global file rollback'
  assert_same "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv" 'missing global file rollback changed source'
  rm "$TEST_WORK/lib/nginx/zz_shared_header_editor.sh"
  run_cli update-backend-header example.com response X-Trace after-missing-global
  assert_same "$TEST_WORK/missing-global-original.csv" "$CONFIG/custom_headers.csv" 'backend mutation did not initialize the empty global header file'
  grep -Fxq 'response,X-Trace,after-missing-global' "$DOMAIN/config/headers.csv" || fail_test 'missing-global backend mutation lost requested header'
  assert_same "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv" 'missing-global backend mutation did not publish its applied source'
}

# A selector isolates each race when reproducing it on an older revision.
# Normal suite execution always exercises every case and the remaining checks.
case "${HEADER_CASE_REPAIR_SCENARIO:-}" in
'' | global_before_publish | global_reload | backend_reload | global_held_inode | global_deleted | backend_missing_global) ;;
*) fail_test 'Unknown HEADER_CASE_REPAIR_SCENARIO' ;;
esac

# Seed both domains with one apply. An identical duplicate in the other owner
# must remain in source/applied even when its generated compatibility view is
# coalesced, including after a later command changes the first owner.
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  mkdir -p "$CONFIG_DIR"
  state_csv_ensure_all_state_files
  # Keep real transaction snapshots, without optional post-command archives.
  ENABLE_AUTO_BACKUPS=false ENABLE_BACKUP_COMPRESSION=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
  domain_config_write_template example.com backend "$DOMAIN/config"
  domain_config_write_template other.example.com backend "$OTHER/config"
  _domain_csv_set "$DOMAIN/config/backend.csv" image nginx:alpine
  _domain_csv_set "$OTHER/config/backend.csv" image nginx:alpine
  csv_join_row 18180 8080 http '' '' no off '' off auto >>"$DOMAIN/config/ports.csv"
  csv_join_row response X-Trace first >>"$DOMAIN/config/headers.csv"
  csv_join_row request X-Trace request-value >>"$DOMAIN/config/headers.csv"
  csv_join_row response X-Other other-value >>"$OTHER/config/headers.csv"
  csv_join_row response x-other other-value >>"$OTHER/config/headers.csv"
)
cp "$OTHER/config/headers.csv" "$TEST_WORK/other-headers-original"
printf '[TEST] Apply identical variants without rewriting source files\n'
run_cli apply-domain-config --all
assert_same "$TEST_WORK/other-headers-original" "$OTHER/config/headers.csv" 'apply rewrote identical source variants'
assert_same "$TEST_WORK/other-headers-original" "$OTHER/runtime/applied/headers.csv" 'apply changed stored spelling/rows'
[ "$(awk -F, '$1 == "other.example.com" && $2 == "response" && tolower($3) == "x-other" { count++ } END { print count+0 }' "$CONFIG/backend_headers.csv")" = 1 ] || fail_test 'compiled view did not coalesce identical owner variants'

for shared_scenario in global_before_publish global_reload backend_reload global_held_inode global_deleted; do
  if [ -n "${HEADER_CASE_REPAIR_SCENARIO:-}" ] && [ "$HEADER_CASE_REPAIR_SCENARIO" != "$shared_scenario" ]; then continue; fi
  shared_header_editor_race "$shared_scenario"
done
if [ -z "${HEADER_CASE_REPAIR_SCENARIO:-}" ] || [ "$HEADER_CASE_REPAIR_SCENARIO" = backend_missing_global ]; then
  missing_global_header_file
fi
if [ -n "${HEADER_CASE_REPAIR_SCENARIO:-}" ]; then
  printf '[PASS] Selected header repair scenario: %s\n' "$HEADER_CASE_REPAIR_SCENARIO"
  exit 0
fi

printf '[TEST] Ordinary commands preserve unrelated stored duplicate spellings\n'
run_cli set-backend-http-version example.com http2
assert_same "$TEST_WORK/other-headers-original" "$OTHER/config/headers.csv" 'ordinary command rewrote unrelated source variants'
assert_same "$TEST_WORK/other-headers-original" "$OTHER/runtime/applied/headers.csv" 'ordinary command rewrote unrelated applied variants'

printf '[TEST] Case-insensitive explicit setter and removal\n'
run_cli update-backend-header EXAMPLE.COM response x-TRACE replacement
[ "$(count_identity "$DOMAIN/config/headers.csv" response x-trace)" = 1 ] || fail_test 'setter appended a different-case duplicate'
grep -Fxq 'response,x-TRACE,replacement' "$DOMAIN/config/headers.csv" || fail_test 'setter did not retain chosen spelling/value'
grep -Fxq 'request,X-Trace,request-value' "$DOMAIN/config/headers.csv" || fail_test 'setter changed request scope'
run_cli remove-backend-header example.com response X-tRaCe
[ "$(count_identity "$DOMAIN/config/headers.csv" response x-trace)" = 0 ] || fail_test 'removal ignored alternate capitalization'

# Historical applied conflicts must be repairable before ordinary bootstrap
# validation. Unrelated pending drafts and duplicate spellings remain intact.
printf '[TEST] Repair historical applied conflicts beside pending drafts\n'
seed_conflict
snapshot_runtime
reject_cli update-nginx-config
assert_runtime_unchanged 'normal conflicting-header validation'
printf 'operator draft,not valid settings\n' >"$OTHER/config/settings.csv"
mkdir "$OTHER/config/notes"
printf 'keep this draft\n' >"$OTHER/config/notes/operator-note"
cp -R "$OTHER/config" "$TEST_WORK/other-draft"
run_cli update-backend-header example.com response x-REPAIR repaired
[ "$(count_identity "$DOMAIN/config/headers.csv" response x-repair)" = 1 ] || fail_test 'explicit repair did not consolidate all variants'
grep -Fxq 'response,x-REPAIR,repaired' "$DOMAIN/config/headers.csv" || fail_test 'explicit repair lost chosen value'
assert_same "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv" 'repair did not publish its applied snapshot'
diff -r "$TEST_WORK/other-draft" "$OTHER/config" >/dev/null || fail_test 'repair overwrote an unrelated draft'
assert_same "$TEST_WORK/other-headers-original" "$OTHER/runtime/applied/headers.csv" 'repair rewrote unrelated applied variants'
seed_conflict
run_cli remove-backend-header example.com response X-REPAIR
[ "$(count_identity "$DOMAIN/config/headers.csv" response x-repair)" = 0 ] || fail_test 'explicit removal did not delete all conflicting variants'
grep -Fxq 'request,X-Repair,request-value' "$DOMAIN/config/headers.csv" || fail_test 'removal changed the other scope'

# The same pre-validation repair path also applies to shared global headers.
printf '[TEST] Global conflict repair\n'
printf 'header_type,header_name,header_value\nresponse,X-Global,one\nresponse,x-global,two\nrequest,X-Global,request-global\n' >"$CONFIG/custom_headers.csv"
run_cli update-header response x-GLOBAL repaired-global
[ "$(count_identity "$CONFIG/custom_headers.csv" response x-global)" = 1 ] || fail_test 'global repair retained case variants'
grep -Fxq 'response,x-GLOBAL,repaired-global' "$CONFIG/custom_headers.csv" || fail_test 'global repair changed selected spelling/value'
printf 'response,X-Global,conflicting-again\n' >>"$CONFIG/custom_headers.csv"
run_cli remove-header response X-gLoBaL
[ "$(count_identity "$CONFIG/custom_headers.csv" response x-global)" = 0 ] || fail_test 'global removal did not delete all variants'
grep -Fxq 'request,X-Global,request-global' "$CONFIG/custom_headers.csv" || fail_test 'global removal changed request scope'

# A real pending edit to the target is still a hard boundary, even when the
# header conflict itself is present identically in source and applied state.
printf '[TEST] Reject target pending edits before mutation\n'
seed_conflict
cp "$DOMAIN/config/settings.csv" "$TEST_WORK/settings-original"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$DOMAIN/config/settings.csv"
cp -R "$DOMAIN/config" "$TEST_WORK/target-draft"
snapshot_runtime
reject_cli update-backend-header example.com response X-Repair repaired
assert_runtime_unchanged 'pending target rejection'
diff -r "$TEST_WORK/target-draft" "$DOMAIN/config" >/dev/null || fail_test 'target rejection overwrote its draft'
cp "$TEST_WORK/settings-original" "$DOMAIN/config/settings.csv"

# Fixing the requested identity cannot bypass validation of another applied
# owner. Validation must finish privately, before publishing cache or sources.
printf '[TEST] Validate the complete repaired candidate privately\n'
cp "$OTHER/runtime/applied/settings.csv" "$TEST_WORK/other-applied-settings"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\ninvalid-version,,,,,\n' >"$OTHER/runtime/applied/settings.csv"
snapshot_runtime
reject_cli update-backend-header example.com response X-Repair repaired
assert_runtime_unchanged 'invalid candidate rejection'
assert_same "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv" 'invalid candidate rewrote target source'
cp "$TEST_WORK/other-applied-settings" "$OTHER/runtime/applied/settings.csv"

# A manual shared-file edit can occur while transaction snapshots are being
# taken. Reject before publication without restoring an older snapshot over it.
printf '[TEST] Preserve a shared edit made while beginning the transaction\n'
cat >"$TEST_WORK/lib/permissions/zz_header_case_snapshot_race.sh" <<'HOOK'
# shellcheck shell=bash
function begin_transaction() {
  source "$BASE_DIR/lib/backups/begin_transaction.sh"
  begin_transaction "$@" || return 1
  printf 'response,X-Editor,concurrent-value\n' >>"$CUSTOM_HEADERS_FILE"
  printf 'injected\n' >"$BASE_DIR/shared-editor-injected"
}
HOOK
snapshot_runtime
race_status=0
"$BIN" update-backend-header example.com response X-Repair repaired >"$TEST_WORK/output" 2>&1 || race_status=$?
[ -f "$TEST_WORK/shared-editor-injected" ] || fail_test 'shared editor hook did not execute'
[ "$race_status" -ne 0 ] || fail_test 'command ignored shared-file edit during transaction snapshot'
printf 'response,X-Editor,concurrent-value\n' >>"$TEST_WORK/before-config/custom_headers.csv"
assert_runtime_unchanged 'shared edit during transaction snapshot'
assert_same "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv" 'snapshot race changed source'
rm "$TEST_WORK/lib/permissions/zz_header_case_snapshot_race.sh"

# Fail activation after generating partial output. The transaction must put
# cache/applied/generated bytes back, retaining the historical source to retry.
printf '[TEST] Roll back activation failure\n'
cat >"$TEST_WORK/lib/nginx/zz_header_case_failure.sh" <<'HOOK'
# shellcheck shell=bash
function update_nginx_config() {
  printf '# partial header render\n' >"${NGINX_HTTP_CONF_DIR}/backends.conf"
  return 1
}
HOOK
snapshot_runtime
reject_cli update-backend-header example.com response X-Repair repaired
assert_runtime_unchanged 'render rollback'
assert_same "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv" 'render rollback changed source'
rm "$TEST_WORK/lib/nginx/zz_header_case_failure.sh"

# An edit made after candidate preparation but before source publication must
# survive rejection and rollback. Reload the original function only inside the
# injected hook so its ordinary compare-and-swap logic still runs.
printf '[TEST] Preserve edits made before source publication\n'
cat >"$TEST_WORK/lib/domain_config/zz_header_case_race.sh" <<'HOOK'
# shellcheck shell=bash
function _domain_config_source_publish() {
  source "$BASE_DIR/lib/domain_config/publication.sh"
  printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.0,,,,,\n' >"$STATE_DIR/domains/example.com/config/settings.csv"
  _domain_config_source_publish "$@"
}
HOOK
snapshot_runtime
reject_cli update-backend-header example.com response X-Repair repaired
assert_runtime_unchanged 'concurrent edit before publication'
[ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = http1.0 ] || fail_test 'rollback discarded concurrent draft edit'
rm "$TEST_WORK/lib/domain_config/zz_header_case_race.sh"
cp "$TEST_WORK/settings-original" "$DOMAIN/config/settings.csv"

printf '[TEST] Preserve held-inode edits after source publication\n'
# An editor can hold the old inode across the directory swap. The publication
# journal must notice the write, restore that inode, and keep later writes live.
cat >"$TEST_WORK/lib/domain_config/zz_header_case_race.sh" <<'HOOK'
# shellcheck shell=bash
function _domain_config_source_verify() {
  source "$BASE_DIR/lib/domain_config/publication.sh"
  printf 'held-editor-write\n' >&3
  _domain_config_source_verify
}
HOOK
exec 3>>"$DOMAIN/config/settings.csv"
snapshot_runtime
reject_cli update-backend-header example.com response X-Repair repaired
assert_runtime_unchanged 'concurrent edit after publication'
grep -Fxq held-editor-write "$DOMAIN/config/settings.csv" || fail_test 'rollback discarded detached-inode edit'
printf 'held-editor-after-rollback\n' >&3
grep -Fxq held-editor-after-rollback "$DOMAIN/config/settings.csv" || fail_test 'rollback replaced the original editor inode'
exec 3>&-
rm "$TEST_WORK/lib/domain_config/zz_header_case_race.sh"
cp "$TEST_WORK/settings-original" "$DOMAIN/config/settings.csv"
run_cli update-backend-header example.com response X-Repair final-value
assert_same "$DOMAIN/config/headers.csv" "$DOMAIN/runtime/applied/headers.csv" 'retry failed to publish source/applied together'
diff -r "$TEST_WORK/other-draft" "$OTHER/config" >/dev/null || fail_test 'recovery/retry changed unrelated draft'
printf '[PASS] CLI header identity repairs, coalesced views, draft boundaries, private validation, rollback, and concurrent editors\n'
