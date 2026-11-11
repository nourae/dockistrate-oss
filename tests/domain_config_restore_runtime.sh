#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_restore_runtime.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
mkdir -p "$TEST_WORK/tests"
cp -R "$ROOT_DIR/tests/mocks" "$TEST_WORK/tests/"
export PATH="$TEST_WORK/tests/mocks:$PATH" SKIP_DOCKER_CHECKS=false
export DOCKER_MOCK_RUNTIME_DIR="$TEST_WORK/state/tmp/.docker_mock"
export DOCKER_MOCK_LOG_FILE="$TEST_WORK/docker.log"
# Keep the runtime listener set equal to the saved configuration throughout.
export DOCKER_MOCK_PORT_BINDINGS='18180/tcp -> 0.0.0.0:18180'
BIN="$TEST_WORK/dockistrate.sh"
GLOBAL_FILE="$TEST_WORK/state/config/global_settings.csv"
DOMAIN="$TEST_WORK/state/domains/restore.example.com"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function proxy_launches() {
  awk '/^subcommand=run / && / --name nginx-proxy /' "$DOCKER_MOCK_LOG_FILE"
}
function assert_launch() {
  local line="$1" image="$2" memory="$3"
  case "$line" in *" --memory $memory "*) ;; *) fail_test "Proxy did not receive restored memory option $memory" ;; esac
  case "$line" in *" $image "* | *" $image") ;; *) fail_test "Proxy did not launch restored image $image" ;; esac
}
function assert_no_journal() {
  local path=""
  for path in "$TEST_WORK/state/runtime/transactions/"apply.*; do
    [ ! -d "$path" ] || fail_test "Completed restore retained runtime journal $path"
  done
}
function assert_running_image() {
  [ "$(docker inspect -f '{{.Config.Image}}' nginx-proxy)" = "$1" ] || fail_test 'Running proxy image does not match restored configuration'
  [ "$(docker inspect -f '{{.State.Running}}' nginx-proxy)" = true ] || fail_test 'Restored proxy is not running'
}
function certificate_mount() {
  sed -n 's/^mounts=//p' "$DOCKER_MOCK_RUNTIME_DIR/nginx-proxy.meta" | awk -F '|' '$2 == "/etc/letsencrypt"'
}

# Use actual CLI backup/restore, ownership validation, rendering and journals;
# only Docker is mocked. The saved archive and current installation have the
# same listeners and certificate generation, but different image/options.
SKIP_DOCKER_CHECKS=true run_cli set-nginx-docker-opts '--memory 128m'
run_cli add-backend restore.example.com nginx:alpine 8080 http --listen 18180
archived_image="$(test_csv_field "$GLOBAL_FILE" nginx_image)"
cp "$GLOBAL_FILE" "$TEST_WORK/archived-globals"
certificate_mount >"$TEST_WORK/archived-mount"
[ -s "$TEST_WORK/archived-mount" ] || fail_test 'Fixture proxy has no restricted certificate mount'
run_cli create-backup restore-runtime
backup="$(cat "$TEST_WORK/state/backups/last_full_backup.txt")"

current_image=nginx:1.27.5
[ "$archived_image" != "$current_image" ] || fail_test 'Fixture images must differ'
SKIP_DOCKER_CHECKS=true run_cli set-nginx-docker-opts '--memory 256m'
run_cli set-nginx-image "$current_image" never
assert_running_image "$current_image"
certificate_mount >"$TEST_WORK/current-mount"
cmp -s "$TEST_WORK/archived-mount" "$TEST_WORK/current-mount" || fail_test 'Fixture certificate projection changed before restore'
cp "$GLOBAL_FILE" "$TEST_WORK/current-globals"
cp "$TEST_WORK/state/config/backend_identity.csv" "$TEST_WORK/current-identities"
cp "$DOMAIN/generated/nginx/http.conf" "$TEST_WORK/current-generated"

# Fail only after the restored image/options have been activated and passed the
# renderer readiness check. The real rollback must restore both files/runtime.
sed 's/^function check_config() {/function _test_original_check_config() {/' "$TEST_WORK/lib/tokens/check_config.sh" >"$TEST_WORK/check_config"
mv "$TEST_WORK/check_config" "$TEST_WORK/lib/tokens/check_config.sh"
cat >"$TEST_WORK/lib/tokens/zz_restore_runtime_failure.sh" <<'EOF'
# shellcheck shell=bash
function check_config() {
  _test_original_check_config "$@" || return 1
  if [ "${DOCKISTRATE_TEST_RESTORE_FAILURE:-false}" = true ]; then
    printf 'injected restore post-activation failure\n' >&2
    return 1
  fi
}
EOF
: >"$DOCKER_MOCK_LOG_FILE"
if DOCKISTRATE_TEST_RESTORE_FAILURE=true "$BIN" restore-backup "$backup" >"$TEST_WORK/output" 2>&1; then
  fail_test 'Restore ignored the post-activation failure'
fi
grep -q 'injected restore post-activation failure' "$TEST_WORK/output" || fail_test 'Restore did not reach the intended failure point'
grep -q 'Rolled back\.' "$TEST_WORK/output" || fail_test 'Restore did not complete recovery'
cmp -s "$GLOBAL_FILE" "$TEST_WORK/current-globals" || fail_test 'Failed restore changed configured image/options'
cmp -s "$TEST_WORK/state/config/backend_identity.csv" "$TEST_WORK/current-identities" || fail_test 'Failed restore changed backend ownership'
cmp -s "$DOMAIN/generated/nginx/http.conf" "$TEST_WORK/current-generated" || fail_test 'Failed restore changed generated domain configuration'
assert_running_image "$current_image"
[ "$(proxy_launches | wc -l | tr -d ' ')" = 2 ] || fail_test 'Failed restore must recreate once for activation and once for recovery'
assert_launch "$(proxy_launches | head -n 1)" "$archived_image" 128m
assert_launch "$(proxy_launches | tail -n 1)" "$current_image" 256m
assert_no_journal

: >"$DOCKER_MOCK_LOG_FILE"
run_cli restore-backup "$backup"
cmp -s "$GLOBAL_FILE" "$TEST_WORK/archived-globals" || fail_test 'Successful restore did not publish saved globals'
cmp -s "$TEST_WORK/state/config/backend_identity.csv" "$TEST_WORK/current-identities" || fail_test 'Successful restore changed backend ownership'
assert_running_image "$archived_image"
[ "$(proxy_launches | wc -l | tr -d ' ')" = 1 ] || fail_test 'Restore must perform exactly one proxy recreation'
assert_launch "$(proxy_launches)" "$archived_image" 128m
if grep -q '^subcommand=exec nginx-proxy nginx -s reload' "$DOCKER_MOCK_LOG_FILE"; then fail_test 'Restore reloaded before recreating the proxy'; fi
certificate_mount >"$TEST_WORK/restored-mount"
cmp -s "$TEST_WORK/archived-mount" "$TEST_WORK/restored-mount" || fail_test 'Restore unexpectedly changed the certificate projection'
assert_no_journal
printf '[PASS] restore activates saved proxy image/options and recovers after activation failure\n'
