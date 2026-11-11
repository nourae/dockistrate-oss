#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_migration_unowned.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
cp -R "$ROOT_DIR/tests/mocks" "$TEST_WORK/mocks"
export PATH="$TEST_WORK/mocks:$PATH" SKIP_DOCKER_CHECKS=false
export DOCKER_MOCK_RUNTIME_DIR="$TEST_WORK/mock-runtime" DOCKER_MOCK_LOG_FILE="$TEST_WORK/docker.log"
BIN="$TEST_WORK/dockistrate.sh"
cd "$TEST_WORK"

function fail_test() {
  printf '[FAIL] %s\n' "$*" >&2
  cat "$TEST_WORK/output" >&2 2>/dev/null || true
  exit 1
}
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function reject_cli() {
  if "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1; then fail_test "Unexpected command success: $*"; fi
}
function fingerprint() {
  (cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do printf '%s\n' "$file"; cksum <"$file"; done)
}
function assert_no_migration_runtime_changes() {
  fingerprint "$DOCKER_MOCK_RUNTIME_DIR" >"$TEST_WORK/docker-after"
  cmp -s "$TEST_WORK/docker-before" "$TEST_WORK/docker-after" || fail_test 'Migration changed a container or network'
  if grep -Eq '^subcommand=(run|create|start|stop|restart|rm|rename|exec|network) ' "$DOCKER_MOCK_LOG_FILE"; then
    fail_test 'Migration attempted a runtime mutation'
  fi
}
function assert_no_journal() {
  local journal=""
  for journal in "$TEST_WORK/state/runtime/transactions/"apply.*; do
    [ ! -d "$journal" ] || fail_test 'Replacement retained an unresolved journal'
  done
}

# Legacy containers belong to no saved identity. Only the mock is invoked to
# create this pre-existing external runtime; Dockistrate must leave it alone.
first=migrate-first.example.com second=migrate-second.example.com
first_id="$(docker run -d --name "backend-$first" --network dockistrate-net nginx:alpine)"
second_id="$(docker run -d --name "backend-$second" --network dockistrate-net nginx:alpine)"
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  source "$TEST_WORK/lib/domain_config.sh"
  STATE_DIR="$TEST_WORK/state"; CERTS_DIR="$STATE_DIR/certs"
  _domain_config_bind_config "$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR/nginx_conf/conf.d" "$CERTS_DIR"
  config_reset_defaults
  ENABLE_AUTO_BACKUPS=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  state_security_rules_use_schema 1
  state_csv_ensure_all_state_files
  printf '1\n' >"$CONFIG_DIR/state_schema_version"
  for domain in "$first" "$second"; do
    state_backend_ports_row_backend "$domain" 172.30.0.2:8080 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
    port=38180; [ "$domain" != "$second" ] || port=38181
    state_backend_ports_row_port "$domain" "$port" 8080 http none no off '' >>"$BACKEND_PORTS_FILE"
  done
  printf '# Existing serving configuration must survive storage migration.\n' >"$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
)
identity="$TEST_WORK/state/config/backend_identity.csv"
cp "$identity" "$TEST_WORK/identity-before"
fingerprint "$DOCKER_MOCK_RUNTIME_DIR" >"$TEST_WORK/docker-before"
fingerprint "$TEST_WORK/state/config" >"$TEST_WORK/config-before"
: >"$DOCKER_MOCK_LOG_FILE"
reject_cli migrate-state --dry-run
fingerprint "$TEST_WORK/state/config" >"$TEST_WORK/config-after"
cmp -s "$TEST_WORK/config-before" "$TEST_WORK/config-after" || fail_test 'Missing details changed legacy config'
[ ! -e "$TEST_WORK/state/domains" ] || fail_test 'Missing details created domain state'
assert_no_migration_runtime_changes

printf 'domain,image,state\n%s,nginx:alpine,running\n%s,nginx:alpine,running\n' "$first" "$second" >"$TEST_WORK/details.csv"
# Details must not bypass a malformed identity or a syntactically valid saved
# identity whose immutable object lacks the recorded ownership labels/token.
for invalid in malformed mismatch; do
  if [ "$invalid" = malformed ]; then
    printf 'domain,container_id,ownership_token\n%s,invalid,bad\n' "$first" >"$identity"
  else
    printf 'domain,container_id,ownership_token\n%s,%s,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$first" "$first_id" >"$identity"
  fi
  fingerprint "$TEST_WORK/state/config" >"$TEST_WORK/rejected-before"
  for mode in dry-run migration; do
    args=(migrate-state --backend-details "$TEST_WORK/details.csv")
    [ "$mode" != dry-run ] || args+=(--dry-run)
    reject_cli "${args[@]}"
    fingerprint "$TEST_WORK/state/config" >"$TEST_WORK/config-after"
    cmp -s "$TEST_WORK/rejected-before" "$TEST_WORK/config-after" || fail_test "$invalid identity rejection changed state"
    [ ! -e "$TEST_WORK/state/domains" ] || fail_test "$invalid identity was imported"
    assert_no_migration_runtime_changes
  done
done
cp "$TEST_WORK/identity-before" "$identity"
: >"$DOCKER_MOCK_LOG_FILE"
run_cli migrate-state --dry-run --backend-details "$TEST_WORK/details.csv"
fingerprint "$TEST_WORK/state/config" >"$TEST_WORK/config-after"
cmp -s "$TEST_WORK/config-before" "$TEST_WORK/config-after" || fail_test 'Dry-run modified legacy state'
[ ! -e "$TEST_WORK/state/domains" ] || fail_test 'Dry-run created domain state'
assert_no_migration_runtime_changes
run_cli migrate-state --backend-details "$TEST_WORK/details.csv"
assert_no_migration_runtime_changes
if grep -Eq '^subcommand=(inspect|ps) .*backend-migrate-' "$DOCKER_MOCK_LOG_FILE"; then
  fail_test 'Explicit details caused a container-name lookup'
fi
cmp -s "$TEST_WORK/identity-before" "$identity" || fail_test 'Storage migration adopted a container identity'
[ "$(cat "$TEST_WORK/state/config/state_schema_version")" = 5 ] || fail_test 'Migration omitted schema 5'
grep -Fq '# Existing serving configuration' "$TEST_WORK/state/config/nginx_conf/conf.d/backends.conf" || fail_test 'Migration replaced serving config'
for domain in "$first" "$second"; do
  applied="$TEST_WORK/state/domains/$domain/runtime/applied"
  [ "$(test_csv_field "$applied/backend.csv" image)" = 'nginx:alpine' ] || fail_test 'Migration lost explicit image'
  [ "$(test_csv_field "$applied/backend.csv" state)" = 'running' ] || fail_test 'Migration lost explicit lifecycle'
  [ ! -e "$TEST_WORK/state/domains/$domain/runtime/observed.csv" ] || fail_test 'Migration invented an observed identity'
done

# Real CLI bootstrap can compile this imported model without ownership data.
# Only explicit full-ID recreation grants ownership, one backend at a time.
untouched="$(grep "^backend,$second," "$TEST_WORK/state/config/backend_ports.csv")"
run_cli update-backend "$first" --replace-unmanaged-container "$first_id" --image nginx:alpine
first_replacement="$(docker inspect -f '{{.Id}}' "backend-$first")"
[ "$first_replacement" != "$first_id" ] || fail_test 'Explicit replacement retained the legacy object'
grep -Eq "^$first,$first_replacement,[0-9a-f]{32}$" "$identity" || fail_test 'First replacement did not record verified ownership'
! grep -q "^$second," "$identity" || fail_test 'First replacement adopted its neighbor'
[ "$untouched" = "$(grep "^backend,$second," "$TEST_WORK/state/config/backend_ports.csv")" ] || fail_test 'First replacement changed its legacy neighbor route'
reject_cli update-nginx-config
grep -Fq 'identity' "$TEST_WORK/output" || fail_test 'Ordinary refresh failed for an unrelated reason'

# Fail after replacement, render and source publication but before durable
# commit. The original full ID and the already-committed neighbor must survive.
fingerprint "$TEST_WORK/state/domains/$second/config" >"$TEST_WORK/source-before"
fingerprint "$TEST_WORK/state/domains/$second/runtime/applied" >"$TEST_WORK/applied-before"
cp "$identity" "$TEST_WORK/replacement-identity-before"
sed 's/^function domain_config_runtime_commit() {/function _test_original_runtime_commit() {/' \
  "$TEST_WORK/lib/domain_config/runtime_journal.sh" >"$TEST_WORK/runtime_journal.sh"
mv "$TEST_WORK/runtime_journal.sh" "$TEST_WORK/lib/domain_config/runtime_journal.sh"
cat >"$TEST_WORK/lib/domain_config/zz_migration_commit_failure.sh" <<'EOF'
# shellcheck shell=bash
function domain_config_runtime_commit() {
  if [ -f "$BASE_DIR/fail-commit" ]; then
    printf 'late commit failure\n' >"$BASE_DIR/commit-failure-reached"
    return 1
  fi
  _test_original_runtime_commit "$@"
}
EOF
: >"$TEST_WORK/fail-commit"
reject_cli update-backend "$second" --replace-unmanaged-container "$second_id" --image nginx:alpine
[ -f "$TEST_WORK/commit-failure-reached" ] || fail_test 'Replacement did not reach the late failure'
grep -Fq 'Rolled back.' "$TEST_WORK/output" || fail_test 'Replacement rollback did not complete'
rm "$TEST_WORK/fail-commit"
[ "$(docker inspect -f '{{.Id}}' "backend-$second")" = "$second_id" ] || fail_test 'Rollback lost the exact original container'
[ "$(docker inspect -f '{{.State.Status}}' "$second_id")" = running ] || fail_test 'Rollback lost the original running state'
[ "$(docker inspect -f '{{.Id}}' "backend-$first")" = "$first_replacement" ] || fail_test 'Rollback changed its committed neighbor'
cmp -s "$TEST_WORK/replacement-identity-before" "$identity" || fail_test 'Rollback left a replacement identity'
fingerprint "$TEST_WORK/state/domains/$second/config" >"$TEST_WORK/source-after"
fingerprint "$TEST_WORK/state/domains/$second/runtime/applied" >"$TEST_WORK/applied-after"
cmp -s "$TEST_WORK/source-before" "$TEST_WORK/source-after" || fail_test 'Rollback changed source configuration'
cmp -s "$TEST_WORK/applied-before" "$TEST_WORK/applied-after" || fail_test 'Rollback changed accepted configuration'
assert_no_journal

run_cli update-backend "$second" --replace-unmanaged-container "$second_id" --image nginx:alpine
second_replacement="$(docker inspect -f '{{.Id}}' "backend-$second")"
[ "$second_replacement" != "$second_id" ] || fail_test 'Replacement retry retained the legacy object'
grep -Eq "^$second,$second_replacement,[0-9a-f]{32}$" "$identity" || fail_test 'Retry did not record verified ownership'
run_cli update-nginx-config
assert_no_journal
printf '[PASS] explicit migration details preserve unowned runtime and sequential replacement rollback\n'
