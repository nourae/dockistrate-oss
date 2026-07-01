#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE_LOG_FILE="state/logs/docker_manager.log"

# shellcheck source=tests/lib/state_sandbox.sh
source "$ROOT_DIR/tests/lib/state_sandbox.sh"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

trap dockistrate_test_state_sandbox_restore EXIT
dockistrate_test_state_sandbox "$ROOT_DIR"

cd "$ROOT_DIR"
rm -rf state
mkdir -p state

SKIP_DOCKER_CHECKS=true ./dockistrate.sh set-nginx-docker-opts "--env NGINX_TOKEN=secret --cpus 1" >/dev/null

rm -f "$VERBOSE_LOG_FILE" state/logs/audit.log

output="$(SKIP_DOCKER_CHECKS=true ./dockistrate.sh -v set-visibility-policy redacted 2>&1)"
case "$output" in
*"NGINX_TOKEN=secret"*)
  fail_test "verbose set-visibility-policy redacted output leaked saved docker opts: $output"
  ;;
esac
log_output="$(cat "$VERBOSE_LOG_FILE" 2>/dev/null || true)"
case "$log_output" in
*"NGINX_TOKEN=secret"*)
  fail_test "verbose set-visibility-policy redacted xtrace log leaked saved docker opts: $log_output"
  ;;
esac

rm -f "$VERBOSE_LOG_FILE" state/logs/audit.log

output="$(SKIP_DOCKER_CHECKS=true ./dockistrate.sh -v show-nginx-docker-opts 2>&1)"
case "$output" in
*"[REDACTED]"*) ;;
*)
  fail_test "verbose show-nginx-docker-opts output should include redacted value: $output"
  ;;
esac
case "$output" in
*"NGINX_TOKEN=secret"*)
  fail_test "verbose show-nginx-docker-opts output leaked saved docker opts: $output"
  ;;
esac

log_output="$(cat "$VERBOSE_LOG_FILE" 2>/dev/null || true)"
case "$log_output" in
*"NGINX_TOKEN=secret"*)
  fail_test "verbose xtrace log leaked saved docker opts: $log_output"
  ;;
esac

rm -f "$VERBOSE_LOG_FILE" state/logs/audit.log

output="$(printf 'q\n' | SKIP_DOCKER_CHECKS=true ./dockistrate.sh -v -i 2>&1 || true)"
case "$output" in
*"NGINX_TOKEN=secret"*)
  fail_test "verbose interactive picker output leaked saved docker opts: $output"
  ;;
esac
log_output="$(cat "$VERBOSE_LOG_FILE" 2>/dev/null || true)"
case "$log_output" in
*"NGINX_TOKEN=secret"*)
  fail_test "verbose interactive picker xtrace log leaked saved docker opts: $log_output"
  ;;
esac

if output="$(SKIP_DOCKER_CHECKS=true ./dockistrate.sh set-nginx-docker-opts "SECRET=top" 2>&1)"; then
  fail_test "invalid positional docker opts should be rejected"
fi
case "$output" in
*"[REDACTED]"*) ;;
*)
  fail_test "redacted docker opts validation error should show placeholder: $output"
  ;;
esac
case "$output" in
*"SECRET=top"*)
  fail_test "redacted docker opts validation error leaked rejected token: $output"
  ;;
esac

echo "[tests] visibility_policy_verbose_xtrace.sh: PASS"
