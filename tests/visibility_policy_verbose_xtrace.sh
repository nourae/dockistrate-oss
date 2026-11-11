#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/global_csv.sh"
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

SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh set-nginx-docker-opts "--env NGINX_TOKEN=secret --cpus 1" >/dev/null

rm -f "$VERBOSE_LOG_FILE" state/logs/audit.log

# Source the real entrypoint through its read-only help route to check the full
# visibility gate without tracing an entire normal startup. Keep its globals
# and readonly VERSION declarations confined to this subshell.
if ! (
  # shellcheck source=../dockistrate.sh
  source "$ROOT_DIR/dockistrate.sh" help update >/dev/null
  VERBOSE=true
  if dockistrate_redacted_xtrace_needed status; then
    fail_test "valid full visibility unexpectedly suppressed verbose tracing"
  fi
); then
  fail_test "valid full visibility gate failed"
fi

# Full mode must retain actual CLI output and command traces; merely checking
# the visibility gate would miss a change that accidentally disables tracing.
full_output_file="state/tmp/full-verbose-output.txt"
SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh -v show-nginx-docker-opts >"$full_output_file" 2>&1
grep -Fq 'NGINX_TOKEN=secret' "$full_output_file" || fail_test 'full verbose CLI lost operator values'
grep -Fq '[CMD]' "$VERBOSE_LOG_FILE" || fail_test 'full verbose CLI did not persist command traces'
grep -Fq 'NGINX_TOKEN=secret' "$VERBOSE_LOG_FILE" || fail_test 'full verbose CLI trace lost operator values'
grep -Eq '\[session=[0-9]+ elapsed=[0-9]+s\] \[CMD\]' "$VERBOSE_LOG_FILE" || fail_test 'full verbose CLI lost elapsed timing'
grep -Fq 'started at ' "$VERBOSE_LOG_FILE" || fail_test 'full verbose CLI lost its wall-clock anchor'

# Exercise the same full-policy trace path through the actual interactive
# diagnostics picker: status, acknowledge completion, then quit both menus.
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
diagnostics_choice=''
for ((choice_index = 0; choice_index < ${#INTERACTIVE_PICKER_HOME_OPTIONS[@]}; choice_index++)); do
  if [ "${INTERACTIVE_PICKER_HOME_OPTIONS[choice_index]}" = "$INTERACTIVE_PICKER_HOME_DIAGNOSTICS_LABEL" ]; then
    diagnostics_choice=$((choice_index + 1))
    break
  fi
done
[ -n "$diagnostics_choice" ] || fail_test "diagnostics home action is missing"
rm -f "$VERBOSE_LOG_FILE" state/logs/audit.log
printf '%s\n1\n\nq\nq\n' "$diagnostics_choice" | SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh -v -i >"$full_output_file" 2>&1
grep -Fq 'NGINX_TOKEN=secret' "$full_output_file" || fail_test 'full verbose interactive status lost operator values'
grep -Fq '[CMD]' "$VERBOSE_LOG_FILE" || fail_test 'full verbose interactive mode did not persist command traces'
grep -Fq 'NGINX_TOKEN=secret' "$VERBOSE_LOG_FILE" || fail_test 'full verbose interactive trace lost operator values'
rm -f "$full_output_file" "$VERBOSE_LOG_FILE" state/logs/audit.log

output="$(SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh -v set-visibility-policy redacted 2>&1)"
case "$output" in
*"NGINX_TOKEN=secret"*)
  fail_test "verbose set-visibility-policy redacted output leaked saved docker opts: $output"
  ;;
esac
log_output="$(cat "$VERBOSE_LOG_FILE" 2>/dev/null || true)"
case "$log_output" in
*"[CMD]"*) ;;
*)
  fail_test "verbose mode should persist command traces in the log under the active Bash version"
  ;;
esac
case "$log_output" in
*"NGINX_TOKEN=secret"*)
  fail_test "verbose set-visibility-policy redacted xtrace log leaked saved docker opts: $log_output"
  ;;
esac

rm -f "$VERBOSE_LOG_FILE" state/logs/audit.log

output="$(SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh -v show-nginx-docker-opts 2>&1)"
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

output="$(printf 'q\n' | SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh -v -i 2>&1 || true)"
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

if output="$(SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh set-nginx-docker-opts "SECRET=top" 2>&1)"; then
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

# A rejected atomic load must not leave the default full visibility active for
# tracing. Put the harmless marker before the invalid row so a leaked bootstrap
# trace would expose it before validation stops; no Docker calls are required.
test_global_csv_seed state/config/global_settings.csv VISIBILITY_POLICY redacted \
  NGINX_DOCKER_OPTS '--env NGINX_TOKEN=secret --cpus 1' HTTP_VERSION invalid-version

# Follow the real home diagnostics picker to select status, acknowledge the
# preparation error, then quit both menus.
for mode in cli interactive; do
  rm -f "$VERBOSE_LOG_FILE" state/logs/audit.log
  if [ "$mode" = cli ]; then
    if output="$(SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh -v status 2>&1)"; then
      fail_test "verbose CLI accepted malformed persisted settings"
    fi
  else
    output="$(printf '%s\n1\n\nq\nq\n' "$diagnostics_choice" | SKIP_DOCKER_CHECKS=true "$BASH" ./dockistrate.sh -v -i 2>&1 || true)"
  fi
  case "$output" in
  *"Invalid persisted setting HTTP_VERSION"*) ;;
  *) fail_test "verbose $mode did not report the invalid persisted setting" ;;
  esac
  case "$output" in
  *"NGINX_TOKEN=secret"*) fail_test "verbose $mode output leaked saved options after rejected load" ;;
  esac
  log_output="$(cat "$VERBOSE_LOG_FILE" 2>/dev/null || true)"
  case "$log_output" in
  *"NGINX_TOKEN=secret"*) fail_test "verbose $mode trace leaked saved options after rejected load" ;;
  esac
done

echo "[tests] visibility_policy_verbose_xtrace.sh: PASS"
