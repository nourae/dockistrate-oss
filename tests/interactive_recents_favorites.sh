#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/common.sh
source "$ROOT_DIR/lib/utils/common.sh"
# shellcheck source=../lib/utils/fs.sh
source "$ROOT_DIR/lib/utils/fs.sh"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/command_alias.sh
source "$ROOT_DIR/lib/cli/command_alias.sh"
# shellcheck source=../lib/cli/command_description.sh
source "$ROOT_DIR/lib/cli/command_description.sh"
# shellcheck source=../lib/cli/command_descriptions.sh
source "$ROOT_DIR/lib/cli/command_descriptions.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/review_command.sh
source "$ROOT_DIR/lib/cli/review_command.sh"
# shellcheck source=../lib/cli/interactive_recents.sh
source "$ROOT_DIR/lib/cli/interactive_recents.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-recents.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

CONFIG_DIR="${tmp_dir}/config"
mkdir -p "$CONFIG_DIR"
INTERACTIVE_RECENTS_NOW="2026-05-04T12:00:00+0000"
SELECTED_CMD=""
SELECTED_ARGS=()
CHOICE_QUEUE=()
CHOICE_CURSOR=0
PREPARE_RUNTIME_CALLS=0
INTERACTIVE=true
AVAILABILITY_STATUS=0
AVAILABILITY_CALLS=0
GUIDANCE_STATUS=1
GUIDANCE_ACTION=""
GUIDANCE_CALLS=0
PROMPTED_CMD=""

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

function reset_selection() {
  SELECTED_CMD=""
  SELECTED_ARGS=()
  CHOICE_QUEUE=("$@")
  CHOICE_CURSOR=0
}

function get_arg_spec() {
  local cmd="${1:-}"
  case "$cmd" in
  status)
    printf '%s' ''
    ;;
  start-nginx)
    printf '%s' 'nginx_image,nginx:latest;docker_opts,'
    ;;
  add-port)
    printf '%s' 'domain,;nginx_port,;container_port,;protocol,http;cert_path,none;ws,no;http3,off;alt_svc,auto'
    ;;
  update-backend)
    printf '%s' 'domain,;image,;docker_opts,'
    ;;
  *)
    return 1
    ;;
  esac
}

function choose_option() {
  local __idx_var="${1:-}"
  if [ "$CHOICE_CURSOR" -ge "${#CHOICE_QUEUE[@]}" ]; then
    echo "[Error] choose_option called unexpectedly or queue exhausted." >&2
    exit 1
  fi
  printf -v "$__idx_var" '%s' "${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  return 0
}

function read_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" default="${3:-}"
  printf -v "$__var" '%s' "$default"
}

function dockistrate_prepare_runtime() {
  PREPARE_RUNTIME_CALLS=$((PREPARE_RUNTIME_CALLS + 1))
}

function interactive_command_availability() {
  local _cmd="${1:-}"
  AVAILABILITY_CALLS=$((AVAILABILITY_CALLS + 1))
  [ "$AVAILABILITY_STATUS" -eq 0 ]
}

function interactive_no_state_guidance() {
  local _cmd="${1:-}"
  GUIDANCE_CALLS=$((GUIDANCE_CALLS + 1))
  INTERACTIVE_NO_STATE_ACTION="$GUIDANCE_ACTION"
  return "$GUIDANCE_STATUS"
}

function interactive_picker_run_command_prompt() {
  local cmd="${1:-}"
  PROMPTED_CMD="$cmd"
  SELECTED_CMD="$cmd"
  SELECTED_ARGS=()
}

function assert_row_count() {
  local file="${1:-}" header="${2:-}" expected="${3:-0}" count
  count="$(csv_data_row_count "$file" "$header")"
  if [ "$count" -ne "$expected" ]; then
    echo "[Error] Expected ${expected} data rows in ${file}, got ${count}." >&2
    cat "$file" >&2
    exit 1
  fi
}

function assert_selected_args() {
  local expected=("$@")
  local idx
  if [ "${#SELECTED_ARGS[@]}" -ne "${#expected[@]}" ]; then
    echo "[Error] Expected ${#expected[@]} selected args, got ${#SELECTED_ARGS[@]}." >&2
    exit 1
  fi
  for idx in "${!expected[@]}"; do
    if [ "${SELECTED_ARGS[$idx]}" != "${expected[$idx]}" ]; then
      echo "[Error] Selected arg ${idx} mismatch: expected '${expected[$idx]}', got '${SELECTED_ARGS[$idx]}'." >&2
      exit 1
    fi
  done
}

recent_file="$(interactive_recent_file)"
favorites_file="$(interactive_favorites_file)"

interactive_record_recent_command status
assert_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER" 1
interactive_load_recent_commands
if [ "${INTERACTIVE_SAVED_COMMANDS[0]}" != "status" ] || [ "${INTERACTIVE_SAVED_ARG_COUNTS[0]}" != "0" ]; then
  echo "[Error] status recent was not loaded correctly." >&2
  exit 1
fi

interactive_record_recent_command add-port "comma,value" "quote\"value" "space value" "http" "none" "no" "off" "h3=\":443\"; ma=60"
interactive_load_recent_commands
_interactive_saved_parse_args "${INTERACTIVE_SAVED_ARG_COUNTS[0]}" "${INTERACTIVE_SAVED_ARGS_CSV[0]}"
if [ "${INTERACTIVE_SAVED_ARGS[0]}" != "comma,value" ] ||
  [ "${INTERACTIVE_SAVED_ARGS[1]}" != "quote\"value" ] ||
  [ "${INTERACTIVE_SAVED_ARGS[2]}" != "space value" ] ||
  [ "${INTERACTIVE_SAVED_ARGS[7]}" != "h3=\":443\"; ma=60" ]; then
  echo "[Error] Recent command args did not round-trip through nested CSV safely." >&2
  exit 1
fi

before_sensitive_count="$(csv_data_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER")"
interactive_record_recent_command update-backend example.com nginx:alpine "--env TOKEN=secret"
after_sensitive_count="$(csv_data_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER")"
if [ "$after_sensitive_count" -ne "$before_sensitive_count" ] || grep -Fq "TOKEN=secret" "$recent_file"; then
  echo "[Error] Sensitive docker_opts args should not be written to interactive recents." >&2
  cat "$recent_file" >&2
  exit 1
fi

before_flag_count="$(csv_data_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER")"
interactive_record_recent_command start-nginx --nginx-image nginx:mainline
after_flag_count="$(csv_data_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER")"
if [ "$after_flag_count" -ne "$((before_flag_count + 1))" ]; then
  echo "[Error] Flag-style non-sensitive args should be written to interactive recents." >&2
  cat "$recent_file" >&2
  exit 1
fi
interactive_record_recent_command start-nginx --docker-opts "--env TOKEN=secret"
after_sensitive_flag_count="$(csv_data_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER")"
if [ "$after_sensitive_flag_count" -ne "$after_flag_count" ] || grep -Fq "TOKEN=secret" "$recent_file"; then
  echo "[Error] Flag-style sensitive docker_opts args should not be written to interactive recents." >&2
  cat "$recent_file" >&2
  exit 1
fi

rm -f "$recent_file"
idx=1
while [ "$idx" -le 12 ]; do
  INTERACTIVE_RECENTS_NOW="2026-05-04T12:00:${idx}+0000"
  interactive_record_recent_command status "$idx"
  idx=$((idx + 1))
done
assert_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER" 10
interactive_load_recent_commands
_interactive_saved_parse_args "${INTERACTIVE_SAVED_ARG_COUNTS[0]}" "${INTERACTIVE_SAVED_ARGS_CSV[0]}"
if [ "${INTERACTIVE_SAVED_ARGS[0]}" != "12" ]; then
  echo "[Error] Latest recent command should be first after retention trim." >&2
  exit 1
fi
_interactive_saved_parse_args "${INTERACTIVE_SAVED_ARG_COUNTS[9]}" "${INTERACTIVE_SAVED_ARGS_CSV[9]}"
if [ "${INTERACTIVE_SAVED_ARGS[0]}" != "3" ]; then
  echo "[Error] Retention should keep the latest 10 recent commands." >&2
  exit 1
fi

rm -f "$recent_file"
INTERACTIVE_RECENTS_LIMIT=0
interactive_record_recent_command status first
interactive_record_recent_command status second
assert_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER" 1
interactive_load_recent_commands
_interactive_saved_parse_args "${INTERACTIVE_SAVED_ARG_COUNTS[0]}" "${INTERACTIVE_SAVED_ARGS_CSV[0]}"
if [ "${INTERACTIVE_SAVED_ARGS[0]}" != "second" ]; then
  echo "[Error] Zero recents limit should be clamped to one retained row." >&2
  exit 1
fi

rm -f "$recent_file"
INTERACTIVE_RECENTS_LIMIT=invalid
idx=1
while [ "$idx" -le 12 ]; do
  INTERACTIVE_RECENTS_NOW="2026-05-04T12:01:${idx}+0000"
  interactive_record_recent_command status "$idx"
  idx=$((idx + 1))
done
assert_row_count "$recent_file" "$STATE_INTERACTIVE_RECENTS_HEADER" 10
INTERACTIVE_RECENTS_LIMIT=10

favorite_args="$(_interactive_command_args_csv example.com 80 8080 http none no off auto)"
interactive_favorite_command add-port 8 "$favorite_args"
if ! interactive_favorite_has_entry add-port 8 "$favorite_args"; then
  echo "[Error] Expected favorite entry after favoriting a recent command." >&2
  exit 1
fi
assert_row_count "$favorites_file" "$STATE_INTERACTIVE_FAVORITES_HEADER" 1
interactive_unfavorite_command add-port 8 "$favorite_args"
if interactive_favorite_has_entry add-port 8 "$favorite_args"; then
  echo "[Error] Favorite entry should be removed after unfavorite." >&2
  exit 1
fi
assert_row_count "$favorites_file" "$STATE_INTERACTIVE_FAVORITES_HEADER" 0

PREPARE_RUNTIME_CALLS=0
AVAILABILITY_STATUS=0
AVAILABILITY_CALLS=0
reset_selection
if ! interactive_picker_run_saved_command status; then
  echo "[Error] Read-only saved command should select without review." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "status" ] || [ "$CHOICE_CURSOR" -ne 0 ]; then
  echo "[Error] Read-only saved command should bypass review chooser." >&2
  exit 1
fi
if [ "$PREPARE_RUNTIME_CALLS" -ne 1 ]; then
  echo "[Error] Saved read-only command should prepare runtime before dispatch." >&2
  exit 1
fi
if [ "$AVAILABILITY_CALLS" -ne 1 ]; then
  echo "[Error] Saved read-only command should check availability before dispatch." >&2
  exit 1
fi

PREPARE_RUNTIME_CALLS=0
AVAILABILITY_STATUS=0
AVAILABILITY_CALLS=0
reset_selection 0
if ! interactive_picker_run_saved_command add-port example.com 80 8080 http none no off auto; then
  echo "[Error] Mutating saved command should run after review Run." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "add-port" ] || [ "$CHOICE_CURSOR" -ne 1 ]; then
  echo "[Error] Mutating saved command should pass through review chooser." >&2
  exit 1
fi
if [ "$PREPARE_RUNTIME_CALLS" -ne 1 ]; then
  echo "[Error] Saved mutating command should prepare runtime before dispatch." >&2
  exit 1
fi
if [ "$AVAILABILITY_CALLS" -ne 1 ]; then
  echo "[Error] Saved mutating command should check availability before review." >&2
  exit 1
fi
assert_selected_args example.com 80 8080 http none no off auto

AVAILABILITY_STATUS=1
AVAILABILITY_CALLS=0
GUIDANCE_STATUS=0
GUIDANCE_ACTION="add-backend"
GUIDANCE_CALLS=0
PROMPTED_CMD=""
PREPARE_RUNTIME_CALLS=0
reset_selection
if ! interactive_picker_run_saved_command remove-port example.com 80; then
  echo "[Error] Saved command with missing state should route to guidance action." >&2
  exit 1
fi
if [ "$AVAILABILITY_CALLS" -ne 1 ] || [ "$GUIDANCE_CALLS" -ne 1 ] || [ "$PROMPTED_CMD" != "add-backend" ]; then
  echo "[Error] Missing-state saved command did not use no-state guidance action." >&2
  exit 1
fi
if [ "$PREPARE_RUNTIME_CALLS" -ne 0 ]; then
  echo "[Error] Missing-state saved command should not prepare runtime for the stale saved command." >&2
  exit 1
fi

AVAILABILITY_STATUS=1
AVAILABILITY_CALLS=0
GUIDANCE_STATUS=3
GUIDANCE_ACTION=""
GUIDANCE_CALLS=0
PROMPTED_CMD=""
PREPARE_RUNTIME_CALLS=0
reset_selection 0
if ! interactive_picker_run_saved_command restore-backup /tmp/external-backup.tar.gz; then
  echo "[Error] Saved restore-backup manual path should proceed to review." >&2
  exit 1
fi
if [ "$AVAILABILITY_CALLS" -ne 1 ] || [ "$GUIDANCE_CALLS" -ne 1 ] || [ "$CHOICE_CURSOR" -ne 1 ]; then
  echo "[Error] Saved restore-backup manual path did not pass through guidance and review." >&2
  exit 1
fi
if [ "$PROMPTED_CMD" != "" ] || [ "$PREPARE_RUNTIME_CALLS" -ne 1 ]; then
  echo "[Error] Saved restore-backup manual path should review/run the saved command without routing to another prompt." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "restore-backup" ]; then
  echo "[Error] Saved restore-backup manual path selected '${SELECTED_CMD}'." >&2
  exit 1
fi
assert_selected_args /tmp/external-backup.tar.gz

AVAILABILITY_STATUS=1
AVAILABILITY_CALLS=0
GUIDANCE_STATUS=1
GUIDANCE_ACTION=""
GUIDANCE_CALLS=0
PROMPTED_CMD=""
reset_selection
result=0
interactive_picker_run_saved_command remove-port example.com 80 || result=$?
if [ "$result" -ne 1 ] || [ -n "$SELECTED_CMD" ] || [ "$GUIDANCE_CALLS" -ne 1 ]; then
  echo "[Error] Missing-state saved command without guidance action should return to the menu." >&2
  exit 1
fi
AVAILABILITY_STATUS=0
GUIDANCE_STATUS=1
GUIDANCE_ACTION=""

# After toggling a favorite from the recents list the chooser should stay in
# the list (continue) rather than returning to the home menu.
# Simulate: (1) load recents with one "status" entry, (2) pick it (idx=0),
# (3) pick "Add to favorites" (action_idx=1), (4) back to list and pick
# "Back" (idx=1 == ${#displays[@]}).
rm -f "$recent_file" "$favorites_file"
INTERACTIVE_RECENTS_NOW="2026-05-04T12:00:00+0000"
interactive_record_recent_command status
# Queue: select entry 0, then action 1 (toggle fav), then Back (idx 1)
CHOICE_QUEUE=(0 1 1)
CHOICE_CURSOR=0
result=0
interactive_picker_choose_saved_entry "Recent commands" "recent" || result=$?
if [ "$result" -ne 1 ]; then
  echo "[Error] Recents chooser should return 1 after Back (got ${result})." >&2
  exit 1
fi
if [ "$CHOICE_CURSOR" -ne 3 ]; then
  echo "[Error] Expected 3 choose_option calls after toggle-then-back in recents (got ${CHOICE_CURSOR})." >&2
  exit 1
fi
if ! interactive_favorite_has_entry status 0 ""; then
  echo "[Error] status should be in favorites after toggling from recents list." >&2
  exit 1
fi

# After unfavoriting the last entry from favorites the chooser should return 1
# (list now empty) after consuming exactly 2 choose_option calls.
CHOICE_QUEUE=(0 1)
CHOICE_CURSOR=0
result=0
interactive_picker_choose_saved_entry "Favorites" "favorites" || result=$?
if [ "$result" -ne 1 ]; then
  echo "[Error] Favorites chooser should return 1 when list becomes empty (got ${result})." >&2
  exit 1
fi
if [ "$CHOICE_CURSOR" -ne 2 ]; then
  echo "[Error] Expected 2 choose_option calls when last favorite removed (got ${CHOICE_CURSOR})." >&2
  exit 1
fi
if interactive_favorite_has_entry status 0 ""; then
  echo "[Error] status should be removed from favorites after unfavoriting." >&2
  exit 1
fi

echo "[tests] interactive_recents_favorites.sh: PASS"
