#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/pre_runtime_commands.sh
source "$ROOT_DIR/lib/cli/pre_runtime_commands.sh"
# shellcheck source=../lib/cli/interactive_picker.sh
source "$ROOT_DIR/lib/cli/interactive_picker.sh"

INTERACTIVE=true
SELECTED_CMD=""
SELECTED_ARGS=()
PREPARE_RUNTIME_COUNT=0
RECENT_RECORD_COUNT=0
RECENT_RECORD_LAST_CMD=""
RECENT_RECORD_LAST_ARG_COUNT=0

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function dockistrate_prepare_runtime() {
  PREPARE_RUNTIME_COUNT=$((PREPARE_RUNTIME_COUNT + 1))
  return 0
}

function prompt_args_for_command() {
  SELECTED_CMD="$1"
  SELECTED_ARGS=()
  return 0
}

function interactive_record_recent_command() {
  RECENT_RECORD_COUNT=$((RECENT_RECORD_COUNT + 1))
  RECENT_RECORD_LAST_CMD="${1:-}"
  shift || true
  RECENT_RECORD_LAST_ARG_COUNT="$#"
}

function record_selected_command_if_allowed() {
  if declare -F interactive_record_recent_command >/dev/null 2>&1 &&
    ! { declare -F dockistrate_command_skips_runtime_prep >/dev/null 2>&1 &&
      dockistrate_command_skips_runtime_prep "${SELECTED_CMD:-}"; }; then
    if [ "${#SELECTED_ARGS[@]}" -gt 0 ]; then
      interactive_record_recent_command "$SELECTED_CMD" "${SELECTED_ARGS[@]}" || true
    else
      interactive_record_recent_command "$SELECTED_CMD" || true
    fi
  fi
}

interactive_picker_run_command_prompt "help-update" ||
  fail_test "interactive help-update prompt should succeed"
[ "$PREPARE_RUNTIME_COUNT" -eq 0 ] ||
  fail_test "help-update should skip dockistrate_prepare_runtime"
record_selected_command_if_allowed
[ "$RECENT_RECORD_COUNT" -eq 0 ] ||
  fail_test "help-update should skip interactive recent-command recording"

interactive_picker_run_command_prompt "upgrade-preflight" ||
  fail_test "interactive upgrade-preflight prompt should succeed"
[ "$PREPARE_RUNTIME_COUNT" -eq 0 ] ||
  fail_test "upgrade-preflight should skip dockistrate_prepare_runtime"
record_selected_command_if_allowed
[ "$RECENT_RECORD_COUNT" -eq 0 ] ||
  fail_test "upgrade-preflight should skip interactive recent-command recording"

interactive_picker_run_command_prompt "status" ||
  fail_test "normal interactive command should still prepare runtime"
[ "$PREPARE_RUNTIME_COUNT" -eq 1 ] ||
  fail_test "normal command should call dockistrate_prepare_runtime exactly once"
record_selected_command_if_allowed
[ "$RECENT_RECORD_COUNT" -eq 1 ] ||
  fail_test "normal command should remain eligible for recent-command recording"
[ "$RECENT_RECORD_LAST_CMD" = "status" ] ||
  fail_test "normal command recent record should use selected command"
[ "$RECENT_RECORD_LAST_ARG_COUNT" -eq 0 ] ||
  fail_test "normal command recent record should preserve selected argument count"

echo "[tests] interactive_update_preflight_no_runtime.sh: PASS"
