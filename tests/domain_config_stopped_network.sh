#!/usr/bin/env bash
# Fixture globals are consumed by sourced production helpers.
# shellcheck disable=SC2034,SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-stopped-network.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$TEST_WORK/"
mkdir -p "$TEST_WORK/tests"
cp -R "$ROOT_DIR/tests/mocks" "$TEST_WORK/tests/"
export PATH="$TEST_WORK/tests/mocks:$PATH" SKIP_DOCKER_CHECKS=false
export DOCKER_MOCK_RUNTIME_DIR="$TEST_WORK/state/tmp/.docker_mock"
export DOCKER_MOCK_LOG_FILE="$TEST_WORK/docker.log" DOCKER_MOCK_EMPTY_STOPPED_IP=true
export DOCKER_MOCK_PORT_BINDINGS='38080/tcp -> 0.0.0.0:38080'
export DOCKER_MOCK_INSPECT_NETWORK_MAP='net-running=10.44.0.9,net-failure=10.44.0.11'
BIN="$TEST_WORK/dockistrate.sh"
DOMAIN="$TEST_WORK/state/domains/example.com"
group="${1:-all}"
case "$group" in all | cli | apply) ;; *) printf 'Usage: %s [all|cli|apply]\n' "$0" >&2; exit 2 ;; esac

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function run_cli() { "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || fail_test "Command failed: $*"; }
function expect_failure() {
  if "$BASH" "$BIN" "$@" >"$TEST_WORK/output" 2>&1; then fail_test "Command unexpectedly succeeded: $*"; fi
}
function assert_membership() {
  [ "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$backend_id")" = "$1" ] || fail_test "Backend is not attached only to $1"
  cmp -s "$TEST_WORK/original-identity" "$TEST_WORK/state/config/backend_identity.csv" || fail_test 'Network change replaced backend identity'
}
function assert_stopped() {
  local network="$1" address=""
  assert_membership "$network"
  [ "$(docker inspect -f '{{.State.Running}}' "$backend_id")" = false ] || fail_test 'Network change started a stopped backend'
  address="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$backend_id")" || fail_test 'Failed to inspect the stopped-container IP'
  [ -z "$address" ] || fail_test 'Mock did not expose an empty stopped-container IP'
  [ "$(test_csv_field "$DOMAIN/runtime/applied/backend.csv" state)" = stopped ] || fail_test 'Network change changed applied lifecycle intent'
  [ "$(test_csv_field "$DOMAIN/runtime/applied/backend.csv" network)" = "$network" ] || fail_test 'Network change did not publish the selected network'
  [ -z "$(test_csv_field "$DOMAIN/runtime/observed.csv" address)" ] || fail_test 'Stopped backend retained a fabricated observed address'
  grep -Fq 'proxy_pass http://dockistrate_unavailable;' "$DOMAIN/generated/nginx/http.conf" || fail_test 'Stopped backend became routable'
}

SNAPSHOT_FILES=(config/backend_ports.csv config/backend_identity.csv config/nginx_conf/conf.d/backends.conf
  domains/example.com/runtime/backend.csv domains/example.com/runtime/observed.csv
  domains/example.com/runtime/applied/backend.csv domains/example.com/runtime/applied/settings.csv
  domains/example.com/generated/nginx/http.conf domains/example.com/config/backend.csv
  domains/example.com/config/settings.csv)
function snapshot_state() {
  local relative=""
  for relative in "${SNAPSHOT_FILES[@]}"; do
    mkdir -p "$TEST_WORK/before/${relative%/*}"
    cp "$TEST_WORK/state/$relative" "$TEST_WORK/before/$relative"
  done
  cp "$DOCKER_MOCK_RUNTIME_DIR/backend-example.com.meta" "$TEST_WORK/before-backend.meta"
  : >"$DOCKER_MOCK_LOG_FILE"
}
function assert_rollback() {
  local settings_changed="${1:-false}" relative=""
  for relative in "${SNAPSHOT_FILES[@]}"; do
    if [ "$settings_changed" = true ] && [ "$relative" = domains/example.com/config/settings.csv ]; then continue; fi
    cmp -s "$TEST_WORK/state/$relative" "$TEST_WORK/before/$relative" || fail_test "Failed operation changed $relative"
  done
  cmp -s "$DOCKER_MOCK_RUNTIME_DIR/backend-example.com.meta" "$TEST_WORK/before-backend.meta" || fail_test 'Failed operation changed container identity, lifecycle or network membership'
}

# Keep fixtures small and use public commands to establish ownership and the
# stopped lifecycle. Docker is mocked; production dispatch and journals run.
(
  source "$TEST_WORK/lib/config.sh"
  source "$TEST_WORK/lib/utils.sh"
  mkdir -p "$CONFIG_DIR"
  state_csv_ensure_all_state_files
  ENABLE_AUTO_BACKUPS=false
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '5\n' >"$STATE_SCHEMA_VERSION_FILE"
)
run_cli add-backend example.com nginx:alpine 8080 http --listen 38080
run_cli stop-backend example.com
backend_id="$(docker inspect -f '{{.Id}}' backend-example.com)"
cp "$TEST_WORK/state/config/backend_identity.csv" "$TEST_WORK/original-identity"
assert_stopped dockistrate-net

if [ "$group" != apply ]; then
  # An existing attachment with no IP must not trigger a redundant connect.
  docker network connect net-update "$backend_id"
  : >"$DOCKER_MOCK_LOG_FILE"
  run_cli update-backend example.com --network net-update
  assert_stopped net-update
  if grep -Fq "subcommand=network connect net-update $backend_id" "$DOCKER_MOCK_LOG_FILE"; then fail_test 'Update reconnected an already attached stopped backend'; fi
  run_cli replace-backend-network example.com net-replace
  assert_stopped net-replace

  snapshot_state
  DOCKER_MOCK_NETWORK_CONNECT_FAIL_FOR=net-failure expect_failure update-backend example.com --network net-failure
  assert_rollback
  grep -Fq "subcommand=network connect net-failure $backend_id" "$DOCKER_MOCK_LOG_FILE" || fail_test 'Connect failure was not exercised'

  # Empty IP does not mean that the old attachment disappeared on failure.
  snapshot_state
  DOCKER_MOCK_NETWORK_DISCONNECT_FAIL_FOR=net-replace expect_failure replace-backend-network example.com net-failure
  assert_rollback
  grep -Fq "subcommand=network disconnect net-replace $backend_id" "$DOCKER_MOCK_LOG_FILE" || fail_test 'Disconnect failure was not exercised'

  # Model external removal directly; the legacy mock preserves its last
  # attachment. A failed disconnect is harmless when that network is absent.
  awk '/^networks=/ { $0 = "networks=" } { print }' "$DOCKER_MOCK_RUNTIME_DIR/backend-example.com.meta" >"$TEST_WORK/detached.meta"
  mv "$TEST_WORK/detached.meta" "$DOCKER_MOCK_RUNTIME_DIR/backend-example.com.meta"
  DOCKER_MOCK_NETWORK_DISCONNECT_FAIL_FOR=net-replace run_cli replace-backend-network example.com net-idempotent
  assert_stopped net-idempotent

  test_domain_csv_set "$DOMAIN/config/settings.csv" http_version http1.0
  snapshot_state
  expect_failure update-backend example.com --network net-pending
  grep -Fq 'Unapplied or invalid edits' "$TEST_WORK/output" || fail_test 'Pending draft was not rejected before mutation'
  assert_rollback
  if grep -Eq '^subcommand=network (connect|disconnect) ' "$DOCKER_MOCK_LOG_FILE"; then fail_test 'Pending draft refusal mutated network membership'; fi
  cp "$DOMAIN/runtime/applied/settings.csv" "$DOMAIN/config/settings.csv"
  printf '[PASS] stopped CLI network updates preserve lifecycle and handle failed membership changes\n'
fi

if [ "$group" != cli ]; then
  test_domain_csv_set "$DOMAIN/config/backend.csv" network net-running
  test_domain_csv_set "$DOMAIN/config/backend.csv" state running
  : >"$DOCKER_MOCK_LOG_FILE"
  run_cli apply-domain-config example.com
  assert_membership net-running
  [ "$(docker inspect -f '{{.State.Running}}' "$backend_id")" = true ] || fail_test 'Apply did not start the backend after changing networks'
  [ "$(test_csv_field "$DOMAIN/runtime/observed.csv" address)" = 10.44.0.9 ] || fail_test 'Apply did not record the actual new network address'
  grep -Fq 'backend,example.com,10.44.0.9:8080,net-running' "$TEST_WORK/state/config/backend_ports.csv" || fail_test 'Apply retained an unavailable or stale upstream address'
  grep -Fq 'proxy_pass http://10.44.0.9:8080;' "$DOMAIN/generated/nginx/http.conf" || fail_test 'Apply did not render the new running upstream'
  grep -Fq "subcommand=start $backend_id" "$DOCKER_MOCK_LOG_FILE" || fail_test 'Apply did not reach the intended stopped-to-running transition'

  run_cli stop-backend example.com
  assert_stopped net-running
  test_domain_csv_set "$DOMAIN/config/backend.csv" network net-failure
  test_domain_csv_set "$DOMAIN/config/backend.csv" state running
  test_domain_csv_set "$DOMAIN/config/settings.csv" http_version http1.0
  snapshot_state
  DOCKER_MOCK_START_FAIL_FOR="$backend_id" expect_failure apply-domain-config example.com
  grep -Fq "subcommand=start $backend_id" "$DOCKER_MOCK_LOG_FILE" || fail_test 'Start failure was not reached after switching networks'
  assert_rollback

  # Fail after real rendering, with a concurrent draft edit that rollback must
  # preserve while restoring the original stopped container and old network.
  cat >"$TEST_WORK/lib/nginx/zz_stopped_network_failure.sh" <<'HOOK'
# shellcheck shell=bash
eval "$(declare -f _update_nginx_config_from_validated_settings | sed '1s/_update_nginx_config_from_validated_settings/_test_stopped_network_render/')"
function _update_nginx_config_from_validated_settings() {
  _test_stopped_network_render || return 1
  if [ "${FAIL_STOPPED_NETWORK_RENDER:-false}" = true ]; then
    _domain_csv_set "$STATE_DIR/domains/example.com/config/settings.csv" http_version http2 || return 1
    printf 'rendered\n' >"$BASE_DIR/network-rendered"
    return 1
  fi
}
HOOK
  snapshot_state
  FAIL_STOPPED_NETWORK_RENDER=true expect_failure apply-domain-config example.com
  [ -f "$TEST_WORK/network-rendered" ] || fail_test 'Render failure was not reached after the backend started'
  assert_rollback true
  [ "$(test_csv_field "$DOMAIN/config/settings.csv" http_version)" = http2 ] || fail_test 'Rollback overwrote the concurrent pending draft'
  printf '[PASS] stopped-to-running network apply refreshes addresses and rolls back start/render failures\n'
fi
